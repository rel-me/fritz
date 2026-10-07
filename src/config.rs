use crate::state::{
    Database,
    rusqlite::{self, params},
};
use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use uuid::Uuid;

pub mod migration;
mod model_locations;
pub use model_locations::ModelLocationStore;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, clap::ValueEnum)]
#[serde(rename_all = "kebab-case")]
pub enum ProviderKind {
    Openai,
    OpenaiDecisions,
    OpenaiCompatible,
    Openrouter,
    Anthropic,
    Gemini,
    Ollama,
    Fritz,
    Jev,
    Ollaya,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum ModelCategory {
    Llm,
    Decision,
}

impl ProviderKind {
    pub fn category(self) -> ModelCategory {
        match self {
            Self::Jev | Self::Ollaya | Self::OpenaiDecisions => ModelCategory::Decision,
            _ => ModelCategory::Llm,
        }
    }
    pub fn is_native(self) -> bool {
        matches!(self, Self::Fritz | Self::Ollaya)
    }
    pub fn requires_key(self) -> bool {
        !matches!(
            self,
            Self::OpenaiCompatible | Self::Ollama | Self::Fritz | Self::Ollaya
        )
    }
    pub fn default_url(self) -> &'static str {
        match self {
            Self::Openai | Self::OpenaiDecisions => "https://api.openai.com/v1",
            Self::OpenaiCompatible => "",
            Self::Openrouter => "https://openrouter.ai/api/v1",
            Self::Anthropic => "https://api.anthropic.com/v1",
            Self::Gemini => "https://generativelanguage.googleapis.com/v1beta",
            Self::Ollama => "http://localhost:11434",
            Self::Fritz | Self::Ollaya => "",
            Self::Jev => "https://api.typesafe.ai/v1/systemone",
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
    pub fn has_same_target(&self, other: &Self) -> bool {
        self.provider == other.provider
            && if self.provider.is_native() {
                self.model_id == other.model_id
            } else {
                self.base_url() == other.base_url()
            }
    }
    pub fn validate(&self) -> Result<()> {
        if self.name.trim().is_empty() {
            bail!("Enter a provider connection name.");
        }
        if self.provider.is_native() {
            if !self.base_url().is_empty() {
                bail!("Fritz runs models on this Mac and does not use an endpoint.");
            }
            if !self.model_id.is_empty() {
                match self.provider {
                    ProviderKind::Ollaya => {
                        crate::decision::local::manifest(&self.model_id)?;
                    }
                    _ => {
                        crate::local::models::manifest(&self.model_id)?;
                    }
                }
            }
            return Ok(());
        }
        if self.provider == ProviderKind::Jev {
            if self
                .base_url
                .as_deref()
                .is_some_and(|url| !url.trim().is_empty())
            {
                bail!("Jev uses TypeSafe's fixed HTTPS endpoint.");
            }
            if !self.model_id.is_empty() && self.model_id != "jev-latest" {
                bail!("Jev currently supports the jev-latest model.");
            }
            return Ok(());
        }
        if self.provider == ProviderKind::OpenaiDecisions
            && !self.model_id.is_empty()
            && self.model_id != "gpt-6-luna"
        {
            bail!("OpenAI Decisions currently supports gpt-6-luna.");
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
    #[serde(default)]
    pub model_directories: std::collections::BTreeMap<String, PathBuf>,
}
impl Default for Registry {
    fn default() -> Self {
        Self {
            version: 1,
            connections: vec![],
            default_connection_id: None,
            model_directories: Default::default(),
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

/// Model weights can be shared independently from provider and conversation data.
pub fn models_dir() -> PathBuf {
    std::env::var_os("FRITZ_MODELS_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join("Models")
        })
}

pub fn model_directories() -> Result<std::collections::BTreeMap<String, PathBuf>> {
    ModelLocationStore::new(data_dir()).load()
}

pub fn remember_model_directory(model_id: &str, directory: &std::path::Path) -> Result<()> {
    ModelLocationStore::new(data_dir()).remember(model_id, directory)
}

pub fn load() -> Result<Registry> {
    load_from(&data_dir())
}
fn load_from(dir: &std::path::Path) -> Result<Registry> {
    RegistryStore::new(dir).load()
}

fn provider_database(dir: &std::path::Path) -> Result<Database> {
    Database::open(&dir.join("providers.sqlite"), &["
        CREATE TABLE providers (id TEXT PRIMARY KEY NOT NULL, position INTEGER NOT NULL, payload TEXT NOT NULL CHECK(json_valid(payload)));
        CREATE TABLE registry (id INTEGER PRIMARY KEY CHECK(id = 1), default_connection_id TEXT REFERENCES providers(id) ON DELETE SET NULL);
        INSERT INTO registry VALUES (1, NULL);
    ", "CREATE TABLE provider_migrations (id TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL CHECK(json_valid(payload)));"], &[("providers", &["id", "position", "payload"]), ("registry", &["id", "default_connection_id"]), ("provider_migrations", &["id", "payload"])])
}

fn read_registry(connection: &rusqlite::Connection) -> Result<Registry> {
    let records = connection
        .prepare("SELECT id, payload FROM providers ORDER BY position")?
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let connections = records
        .iter()
        .map(|(id, record)| {
            let provider: Connection = serde_json::from_str(record)?;
            if provider.id.to_string() != *id {
                bail!("Invalid provider identity in state database.");
            }
            provider.validate()?;
            Ok(provider)
        })
        .collect::<Result<Vec<Connection>>>()?;
    let default: Option<String> = connection.query_row(
        "SELECT default_connection_id FROM registry WHERE id = 1",
        [],
        |row| row.get(0),
    )?;
    Ok(Registry {
        version: 1,
        connections,
        default_connection_id: default.map(|id| Uuid::parse_str(&id)).transpose()?,
        model_directories: Default::default(),
    })
}

pub fn update(f: impl FnOnce(&mut Registry) -> Result<()>) -> Result<Registry> {
    RegistryStore::new(data_dir()).update(f)
}

/// The host owns connection opening, schema migrations, locking and lifetime.
/// This connection must contain the provider tables declared by PROVIDER_SCHEMA.
pub trait ProviderStorage: Send + Sync {
    fn open(&self) -> Result<rusqlite::Connection>;
}

pub const PROVIDER_SCHEMA: &str = "
    CREATE TABLE providers (id TEXT PRIMARY KEY NOT NULL, position INTEGER NOT NULL, payload TEXT NOT NULL CHECK(json_valid(payload)));
    CREATE TABLE registry (id INTEGER PRIMARY KEY CHECK(id = 1), default_connection_id TEXT REFERENCES providers(id) ON DELETE SET NULL);
    INSERT INTO registry VALUES (1, NULL);
    CREATE TABLE provider_migrations (id TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL CHECK(json_valid(payload)));
";

struct FritzProviderStorage {
    directory: PathBuf,
}
impl ProviderStorage for FritzProviderStorage {
    fn open(&self) -> Result<rusqlite::Connection> {
        Ok(provider_database(&self.directory)?.into_connection())
    }
}

/// Provider algorithms operate on an injected host storage implementation.
#[derive(Clone)]
pub struct RegistryStore {
    storage: std::sync::Arc<dyn ProviderStorage>,
}

impl RegistryStore {
    /// Fritz's standalone convenience store. Embedded hosts use with_storage.
    pub fn new(directory: impl Into<PathBuf>) -> Self {
        Self::with_storage(std::sync::Arc::new(FritzProviderStorage {
            directory: directory.into(),
        }))
    }

    pub fn with_storage(storage: std::sync::Arc<dyn ProviderStorage>) -> Self {
        Self { storage }
    }

    pub(crate) fn transaction<T>(
        &self,
        action: impl FnOnce(&rusqlite::Transaction<'_>) -> Result<T>,
    ) -> Result<T> {
        let mut connection = self.storage.open()?;
        let transaction =
            connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let result = action(&transaction)?;
        transaction.commit()?;
        Ok(result)
    }

    pub fn load(&self) -> Result<Registry> {
        self.transaction(|transaction| read_registry(transaction))
    }

    pub fn find(&self, selector: Option<&str>) -> Result<Connection> {
        let registry = self.load()?;
        registry
            .connections
            .into_iter()
            .find(|connection| match selector {
                Some(value) => {
                    Uuid::parse_str(value).ok() == Some(connection.id) || connection.name == value
                }
                None => Some(connection.id) == registry.default_connection_id,
            })
            .context("No provider selected. Add a connection in Models.")
    }

    pub fn update(&self, action: impl FnOnce(&mut Registry) -> Result<()>) -> Result<Registry> {
        self.transaction(|transaction| {
            let mut registry = read_registry(transaction)?;
            action(&mut registry)?;
            write_registry(transaction, &registry)?;
            Ok(registry)
        })
    }
}

fn write_registry(transaction: &rusqlite::Connection, registry: &Registry) -> Result<()> {
    if let Some(default_id) = registry.default_connection_id
        && !registry.connections.iter().any(|connection| {
            connection.id == default_id && connection.provider.category() == ModelCategory::Llm
        })
    {
        bail!("The default chat provider must be an LLM connection.");
    }
    transaction.execute("DELETE FROM providers", [])?;
    for (position, connection) in registry.connections.iter().enumerate() {
        connection.validate()?;
        transaction.execute(
            "INSERT INTO providers VALUES (?1, ?2, ?3)",
            params![
                connection.id.to_string(),
                position,
                serde_json::to_string(connection)?
            ],
        )?;
    }
    transaction.execute(
        "UPDATE registry SET default_connection_id = ?1 WHERE id = 1",
        [registry.default_connection_id.map(|id| id.to_string())],
    )?;
    Ok(())
}

const KEYCHAIN_SERVICE: &str = "dev.fritz.provider-credentials";

pub fn keychain_service() -> String {
    std::env::var("FRITZ_KEYCHAIN_SERVICE")
        .ok()
        .filter(|value| {
            value.starts_with("dev.fritz.provider-credentials.")
                && value.len() <= 100
                && value
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-'))
        })
        .unwrap_or_else(|| KEYCHAIN_SERVICE.to_owned())
}

/// Explicit Keychain namespace for a host application; credentials never enter the registry.
#[cfg(target_os = "macos")]
pub struct CredentialStore {
    service: String,
}

#[cfg(target_os = "macos")]
impl CredentialStore {
    pub fn new(service: impl Into<String>) -> Result<Self> {
        let service = service.into();
        if service.trim().is_empty() {
            bail!("A Keychain service name is required.");
        }
        Ok(Self { service })
    }
    pub fn key(&self, id: Uuid) -> Result<Option<String>> {
        match security_framework::passwords::get_generic_password(&self.service, &id.to_string()) {
            Ok(bytes) => Ok(Some(String::from_utf8(bytes)?)),
            Err(e) if e.code() == -25300 => Ok(None),
            Err(e) => Err(e).context("Could not read the provider key from Keychain."),
        }
    }
    pub fn set_key(&self, id: Uuid, value: &str) -> Result<()> {
        if value.is_empty() {
            return Ok(());
        }
        security_framework::passwords::set_generic_password(
            &self.service,
            &id.to_string(),
            value.as_bytes(),
        )
        .context("Could not save the provider key in Keychain.")
    }
    pub fn delete_key(&self, id: Uuid) -> Result<()> {
        match security_framework::passwords::delete_generic_password(&self.service, &id.to_string())
        {
            Ok(()) => Ok(()),
            Err(e) if e.code() == -25300 => Ok(()),
            Err(e) => Err(e).context("Could not delete the provider key from Keychain."),
        }
    }
}

#[cfg(target_os = "macos")]
pub fn key(id: Uuid) -> Result<Option<String>> {
    CredentialStore::new(keychain_service())?.key(id)
}
#[cfg(target_os = "macos")]
pub fn set_key(id: Uuid, value: &str) -> Result<()> {
    CredentialStore::new(keychain_service())?.set_key(id, value)
}
#[cfg(target_os = "macos")]
pub fn delete_key(id: Uuid) -> Result<()> {
    CredentialStore::new(keychain_service())?.delete_key(id)
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
    fn jev_is_a_decision_model_with_a_fixed_endpoint() {
        assert_eq!(ProviderKind::Jev.category(), ModelCategory::Decision);
        assert_eq!(ProviderKind::Openai.category(), ModelCategory::Llm);
        let mut connection = Connection {
            id: Uuid::new_v4(),
            name: "Jev".into(),
            provider: ProviderKind::Jev,
            base_url: None,
            model_id: "jev-latest".into(),
        };
        connection.validate().unwrap();
        connection.base_url = Some("https://example.com".into());
        assert!(connection.validate().is_err());
    }
    #[test]
    fn decision_connection_cannot_be_default_chat_provider() {
        let directory = tempfile::tempdir().unwrap();
        let store = RegistryStore::new(directory.path());
        let id = Uuid::new_v4();
        assert!(
            store
                .update(|registry| {
                    registry.connections.push(Connection {
                        id,
                        name: "Jev".into(),
                        provider: ProviderKind::Jev,
                        base_url: None,
                        model_id: "jev-latest".into(),
                    });
                    registry.default_connection_id = Some(id);
                    Ok(())
                })
                .is_err()
        );
        assert!(store.load().unwrap().connections.is_empty());
    }
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
        std::fs::write(dir.path().join("providers.sqlite"), "invalid").unwrap();
        assert!(load_from(dir.path()).is_err());
    }
}
