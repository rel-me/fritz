//! Resolve public Hub files to immutable, checksummed downloads.
use super::{ContextLimit, Manifest, ModelStore, download_to, hash_prefix};
use crate::state::rusqlite::{OptionalExtension, params};
use anyhow::{Context, Result, bail, ensure};
use reqwest::{StatusCode, Url};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{fs::File, path::Path, time::Duration};

const HUB: &str = "https://huggingface.co";
const MAX_METADATA_BYTES: usize = 8 * 1024 * 1024;
const GIB: u64 = 1024 * 1024 * 1024;

#[derive(Deserialize)]
struct HubModel {
    sha: String,
    #[serde(default)]
    gated: Value,
    siblings: Vec<HubSibling>,
}

#[derive(Deserialize)]
struct HubSibling {
    rfilename: String,
    lfs: Option<Lfs>,
}

#[derive(Deserialize)]
struct Lfs {
    sha256: String,
    size: u64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Candidate {
    path: String,
    size: u64,
    id: String,
}

struct Repository {
    owner: String,
    name: String,
}

impl Repository {
    fn parse(input: &str) -> Result<Self> {
        let input = input.trim().trim_end_matches('/');
        let path = if let Some(path) = input.strip_prefix("https://huggingface.co/") {
            path.split(['?', '#'])
                .next()
                .unwrap_or_default()
                .trim_end_matches('/')
        } else {
            input
        };
        let (owner, name) = path
            .split_once('/')
            .filter(|(owner, name)| valid_slug(owner) && valid_slug(name))
            .context("Enter a Hugging Face model repository URL or an owner/model ID.")?;
        Ok(Self {
            owner: owner.into(),
            name: name.into(),
        })
    }

    fn id(&self) -> String {
        format!("{}/{}", self.owner, self.name)
    }

    fn url(&self) -> Url {
        Url::parse(&format!("{HUB}/{}", self.id())).expect("validated Hub repository")
    }
}

fn valid_slug(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 96
        && !matches!(value, "." | "..")
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-_.".contains(&byte))
}

fn is_hex(value: &str, length: usize) -> bool {
    value.len() == length && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn supported_path(path: &str) -> bool {
    let Some(filename) = path.rsplit('/').next() else {
        return false;
    };
    let filename = filename.to_ascii_lowercase();
    let Some(stem) = filename.strip_suffix(".gguf") else {
        return false;
    };
    let shard = stem.rsplit_once("-of-").is_some_and(|(prefix, total)| {
        let index = prefix.rsplit('-').next().unwrap_or_default();
        [index, total]
            .into_iter()
            .all(|value| value.len() == 5 && value.bytes().all(|b| b.is_ascii_digit()))
    });
    !shard
        && !filename.contains("mmproj")
        && path.split('/').all(|segment| {
            !segment.is_empty()
                && !matches!(segment, "." | "..")
                && !segment.contains('\\')
                && !segment.chars().any(char::is_control)
        })
}

async fn repository_model(repo: &Repository, revision: Option<&str>) -> Result<HubModel> {
    let mut url = Url::parse(&format!("{HUB}/api/models/{}", repo.id()))?;
    if let Some(revision) = revision {
        ensure!(
            is_hex(revision, 40),
            "The Hugging Face revision is invalid. Look up the repository again."
        );
        url.path_segments_mut()
            .expect("Hub URL has path segments")
            .extend(["revision", revision]);
    }
    url.query_pairs_mut().append_pair("blobs", "true");
    let client = reqwest::Client::builder()
        .user_agent(concat!("Fritz/", env!("CARGO_PKG_VERSION")))
        .https_only(true)
        .timeout(Duration::from_secs(20))
        .build()?;
    let mut response = client
        .get(url)
        .send()
        .await
        .context("Could not reach Hugging Face.")?;
    match response.status() {
        StatusCode::OK => {}
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => {
            bail!(
                "This Hugging Face repository is unavailable without signing in. Choose a public, ungated model."
            )
        }
        StatusCode::NOT_FOUND => bail!("Hugging Face could not find this repository or revision."),
        status => bail!(
            "Hugging Face returned HTTP {}. Try again later.",
            status.as_u16()
        ),
    }
    let mut body = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .context("Could not read Hugging Face model details.")?
    {
        ensure!(
            body.len().saturating_add(chunk.len()) <= MAX_METADATA_BYTES,
            "This Hugging Face repository has too much metadata to list."
        );
        body.extend_from_slice(&chunk);
    }
    let model: HubModel =
        serde_json::from_slice(&body).context("Hugging Face returned invalid model details.")?;
    ensure!(
        matches!(model.gated, Value::Null | Value::Bool(false)),
        "This Hugging Face repository is gated. Choose a public, ungated model."
    );
    ensure!(
        is_hex(&model.sha, 40) && revision.is_none_or(|expected| expected == model.sha),
        "Hugging Face did not return the selected commit."
    );
    Ok(model)
}

fn candidates(model: &HubModel) -> impl Iterator<Item = (&str, &Lfs)> {
    model.siblings.iter().filter_map(|file| {
        let lfs = file.lfs.as_ref()?;
        (supported_path(&file.rfilename) && lfs.size > 0 && is_hex(&lfs.sha256, 64))
            .then_some((file.rfilename.as_str(), lfs))
    })
}

pub(crate) async fn lookup(query: &str) -> Result<Value> {
    let repo = Repository::parse(query)?;
    let model = repository_model(&repo, None).await?;
    let mut files: Vec<_> = candidates(&model)
        .map(|(path, lfs)| Candidate {
            path: path.into(),
            size: lfs.size,
            id: id_for(&lfs.sha256),
        })
        .collect();
    files.sort_by(|a, b| (a.size, &a.path).cmp(&(b.size, &b.path)));
    ensure!(
        !files.is_empty(),
        "This repository has no single-file GGUF weights with a published checksum."
    );
    Ok(json!({"repository":repo.id(),"url":repo.url().as_str(),"revision":model.sha,"files":files}))
}

fn id_for(hash: &str) -> String {
    format!("hf-{}", hash.to_ascii_lowercase())
}

pub(super) fn download_url(pin: &Manifest) -> Result<Url> {
    let repo = Repository::parse(&pin.repository)?;
    let mut url = repo.url();
    url.path_segments_mut()
        .expect("Hub URL has path segments")
        .extend(["resolve", &pin.revision])
        .extend(pin.source_file.as_deref().unwrap_or(&pin.file).split('/'));
    Ok(url)
}

pub(crate) async fn import(
    store: &ModelStore,
    repository: &str,
    revision: &str,
    file: &str,
    emit: &(impl Fn(Value) + Sync),
) -> Result<Value> {
    let repo = Repository::parse(repository)?;
    let model = repository_model(&repo, Some(revision)).await?;
    let (_, lfs) = candidates(&model)
        .find(|(candidate, _)| *candidate == file)
        .context("Choose a single-file GGUF from the listed repository revision.")?;
    let hash = lfs.sha256.to_ascii_lowercase();
    let id = id_for(&hash);
    let mut pin = Manifest {
        name: file
            .rsplit('/')
            .next()
            .unwrap_or_default()
            .trim_end_matches(".gguf")
            .into(),
        file: format!("{id}.gguf"),
        id,
        architecture: String::new(),
        disable_thinking: false,
        limit: ContextLimit {
            context: 0,
            automatic_target: None,
        },
        quantization: None,
        repository: repo.id(),
        revision: model.sha.clone(),
        source_file: Some(file.into()),
        size: lfs.size,
        sha256: hash,
    };
    let directory = store.directory_for(&pin.id);
    let url = download_url(&pin)?;
    let path = directory.join(&pin.file);
    let existing = path.is_file();
    if existing {
        let mut hash = Sha256::new();
        let file = File::open(&path)?;
        ensure!(
            file.metadata()?.len() == pin.size,
            "The existing GGUF has a different size. Check the model storage folder."
        );
        hash_prefix(&file, pin.size, &mut hash).await?;
        ensure!(
            hex::encode(hash.finalize()) == pin.sha256,
            "The existing GGUF failed checksum verification. Check the model storage folder."
        );
    }
    download_to(directory, url.as_str(), &pin, emit).await?;

    let metadata = crate::local::native::gguf_metadata(&path).await;
    let (architecture, context) = match metadata {
        Ok(metadata) => metadata,
        Err(error) => {
            if !existing {
                std::fs::remove_file(&path)
                    .context("Could not remove the unsupported GGUF from model storage.")?;
            }
            return Err(error);
        }
    };
    pin.architecture = architecture;
    pin.limit = ContextLimit {
        context,
        automatic_target: Some(context.min(8192)),
    };
    save(&pin, directory)?;
    Ok(json!({"modelId":pin.id,"installed":true}))
}

fn database() -> Result<crate::state::rusqlite::Connection> {
    Ok(crate::config::model_locations::database(&crate::config::data_dir())?.into_connection())
}

fn save(pin: &Manifest, directory: &Path) -> Result<()> {
    let directory = directory.canonicalize()?;
    let directory = directory
        .to_str()
        .context("Choose a model folder with a valid Unicode path.")?;
    let mut database = database()?;
    let transaction = database.transaction()?;
    transaction.execute(
        "INSERT INTO imported_local_models VALUES (?1, ?2) ON CONFLICT(id) DO NOTHING",
        params![pin.id, serde_json::to_string(pin)?],
    )?;
    transaction.execute(
        "INSERT INTO model_locations VALUES (?1, ?2) ON CONFLICT(model_id) DO UPDATE SET directory = excluded.directory",
        params![pin.id, directory],
    )?;
    transaction.commit()?;
    Ok(())
}

pub(crate) fn catalog() -> Result<Vec<Manifest>> {
    let database = database()?;
    let mut query = database.prepare("SELECT manifest FROM imported_local_models ORDER BY id")?;
    let rows = query.query_map([], |row| row.get::<_, String>(0))?;
    rows.map(|row| Ok(serde_json::from_str(&row?)?)).collect()
}

pub(super) fn manifest(id: &str) -> Result<Manifest> {
    let value: Option<String> = database()?
        .query_row(
            "SELECT manifest FROM imported_local_models WHERE id = ?1",
            [id],
            |row| row.get(0),
        )
        .optional()?;
    let value = value.with_context(|| format!("Unknown Fritz local model: {id}"))?;
    Ok(serde_json::from_str(&value)?)
}

pub(super) fn descriptor(pin: &Manifest) -> Value {
    json!({
        "id":pin.id,"name":pin.name,"family":pin.repository,"category":"llm","size":pin.size,
        "memory_gb": pin.size.div_ceil(GIB) + 4,
        "license_url":format!("{HUB}/{}",pin.repository),
        "limit":pin.limit,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lookup_only_lists_downloadable_single_file_weights() -> Result<()> {
        let hash = "a".repeat(64);
        let lfs = json!({"sha256":hash,"size":1024});
        let model: HubModel = serde_json::from_value(json!({
            "sha": "a".repeat(40),
            "siblings": [
                {"rfilename":"quants/model Q4.gguf","lfs":lfs},
                {"rfilename":"../model.gguf","lfs":lfs},
                {"rfilename":"mmproj-model.gguf","lfs":lfs},
                {"rfilename":"model-00001-of-00002.gguf","lfs":lfs},
                {"rfilename":"model.safetensors","lfs":lfs},
                {"rfilename":"unverified.gguf"}
            ]
        }))?;
        assert_eq!(
            candidates(&model).map(|(path, _)| path).collect::<Vec<_>>(),
            ["quants/model Q4.gguf"]
        );
        assert_eq!(
            Repository::parse("https://huggingface.co/owner/model?x=y")?.id(),
            "owner/model"
        );
        assert!(Repository::parse("https://other.test/owner/model").is_err());
        assert!(Repository::parse("owner/../model").is_err());
        Ok(())
    }
}
