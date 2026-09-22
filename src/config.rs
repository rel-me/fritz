use anyhow::{Context, Result, bail};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, OpenOptions},
    path::PathBuf,
};
use uuid::Uuid;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, clap::ValueEnum)]
#[serde(rename_all = "kebab-case")]
pub enum ProviderKind {
    Openai,
    OpenaiCompatible,
    Openrouter,
    Anthropic,
    Gemini,
    Ollama,
    Fritz,
}

impl ProviderKind {
    pub fn requires_key(self) -> bool {
        !matches!(self, Self::OpenaiCompatible | Self::Ollama | Self::Fritz)
    }
    pub fn default_url(self) -> &'static str {
        match self {
            Self::Openai => "https://api.openai.com/v1",
            Self::OpenaiCompatible => "",
            Self::Openrouter => "https://openrouter.ai/api/v1",
            Self::Anthropic => "https://api.anthropic.com/v1",
            Self::Gemini => "https://generativelanguage.googleapis.com/v1beta",
            Self::Ollama => "http://localhost:11434",
            Self::Fritz => "",
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Connection {
    pub id: Uuid,
    pub name: String,
    pub provider: ProviderKind,
    #[serde(default)]
    pub base_url: Option<String>,
    #[serde(default)]
    pub model_id: String,
}

impl Connection {
    pub fn base_url(&self) -> &str {
        self.base_url
            .as_deref()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or(self.provider.default_url())
            .trim_end_matches('/')
    }
    pub fn validate(&self) -> Result<()> {
        if self.name.trim().is_empty() {
            bail!("Enter a provider connection name.");
        }
        if self.provider == ProviderKind::Fritz {
            if !self.base_url().is_empty() {
                bail!("Fritz runs models on this Mac and does not use an endpoint.");
            }
            if !self.model_id.is_empty() {
                crate::local::models::manifest(&self.model_id)?;
            }
            return Ok(());
        }
        let url = reqwest::Url::parse(self.base_url()).context("Enter a valid endpoint URL.")?;
        if !matches!(url.scheme(), "https" | "http")
            || url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
        {
            bail!("Use an HTTP or HTTPS endpoint without credentials, a query, or a fragment.");
        }
        if url.scheme() == "http"
            && !matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"))
        {
            bail!("Remote endpoints require HTTPS. HTTP is available for local services.");
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Registry {
    pub version: u32,
    pub connections: Vec<Connection>,
    pub default_connection_id: Option<Uuid>,
}
impl Default for Registry {
    fn default() -> Self {
        Self {
            version: 1,
            connections: vec![],
            default_connection_id: None,
        }
    }
}

pub fn data_dir() -> PathBuf {
    std::env::var_os("FRITZ_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
                .join("Library/Application Support/Fritz/Data")
        })
}

pub fn load() -> Result<Registry> {
    load_from(&data_dir())
}
fn load_from(dir: &std::path::Path) -> Result<Registry> {
    let path = dir.join("providers.json");
    let text = match fs::read(path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Registry::default()),
        Err(e) => return Err(e.into()),
    };
    let registry: Registry =
        serde_json::from_slice(&text).context("Could not read Fritz provider settings.")?;
    if registry.version != 1 {
        bail!(
            "Unsupported provider settings version {}.",
            registry.version
        );
    }
    Ok(registry)
}

pub fn update(f: impl FnOnce(&mut Registry) -> Result<()>) -> Result<Registry> {
    let dir = data_dir();
    fs::create_dir_all(&dir)?;
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(dir.join("providers.lock"))?;
    lock.lock_exclusive()?;
    let mut registry = load_from(&dir)?;
    f(&mut registry)?;
    let temporary = dir.join(format!("providers-{}.tmp", Uuid::new_v4()));
    fs::write(&temporary, serde_json::to_vec_pretty(&registry)?)?;
    fs::rename(temporary, dir.join("providers.json"))?;
    Ok(registry)
}

const KEYCHAIN_SERVICE: &str = "dev.fritz.provider-credentials";

#[cfg(target_os = "macos")]
pub fn key(id: Uuid) -> Result<Option<String>> {
    match security_framework::passwords::get_generic_password(KEYCHAIN_SERVICE, &id.to_string()) {
        Ok(bytes) => Ok(Some(String::from_utf8(bytes)?)),
        Err(e) if e.code() == -25300 => Ok(None),
        Err(e) => Err(e).context("Could not read the provider key from Keychain."),
    }
}
#[cfg(target_os = "macos")]
pub fn set_key(id: Uuid, value: &str) -> Result<()> {
    if value.is_empty() {
        return Ok(());
    }
    security_framework::passwords::set_generic_password(
        KEYCHAIN_SERVICE,
        &id.to_string(),
        value.as_bytes(),
    )
    .context("Could not save the provider key in Keychain.")
}
#[cfg(target_os = "macos")]
pub fn delete_key(id: Uuid) -> Result<()> {
    match security_framework::passwords::delete_generic_password(KEYCHAIN_SERVICE, &id.to_string())
    {
        Ok(()) => Ok(()),
        Err(e) if e.code() == -25300 => Ok(()),
        Err(e) => Err(e).context("Could not delete the provider key from Keychain."),
    }
}

pub fn find(selector: Option<&str>) -> Result<Connection> {
    let registry = load()?;
    registry
        .connections
        .iter()
        .find(|c| match selector {
            Some(value) => Uuid::parse_str(value).ok() == Some(c.id) || c.name == value,
            None => Some(c.id) == registry.default_connection_id,
        })
        .cloned()
        .context("No provider selected. Add a connection in Fritz’s Providers screen.")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn validates_endpoint_and_requires_compatible_url() {
        let mut c = Connection {
            id: Uuid::new_v4(),
            name: "Local".into(),
            provider: ProviderKind::OpenaiCompatible,
            base_url: None,
            model_id: String::new(),
        };
        assert!(c.validate().is_err());
        for url in ["http://localhost:9000/v1", "https://example.com/v1"] {
            c.base_url = Some(url.into());
            assert!(c.validate().is_ok());
        }
        for url in [
            "file:///tmp/test",
            "http://example.com",
            "https://secret@example.com",
            "https://example.com?key=secret",
        ] {
            c.base_url = Some(url.into());
            assert!(c.validate().is_err());
        }
    }
    #[test]
    fn invalid_existing_registry_is_not_silently_reset() {
        let dir = tempfile::tempdir().unwrap();
        assert!(load_from(dir.path()).unwrap().connections.is_empty());
        fs::write(dir.path().join("providers.json"), "invalid").unwrap();
        assert!(load_from(dir.path()).is_err());
    }
}
