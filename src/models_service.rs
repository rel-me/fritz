//! Shared Models service with explicit host storage, credentials and model caches.
use crate::{
    config::{self, Connection, CredentialStore, ProviderKind, RegistryStore},
    decision, local, provider,
};
use anyhow::{Context, Result, bail};
use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;

pub struct ModelsService {
    pub registry: RegistryStore,
    credentials: CredentialStore,
    local_models: local::models::ModelStore,
    decision_models: decision::local::ModelStore,
    model_locations: config::ModelLocationStore,
}
impl ModelsService {
    pub fn new(
        registry: RegistryStore,
        credentials: CredentialStore,
        local_models: local::models::ModelStore,
        decision_models: decision::local::ModelStore,
        model_locations: config::ModelLocationStore,
    ) -> Self {
        Self {
            registry,
            credentials,
            local_models,
            decision_models,
            model_locations,
        }
    }
    pub fn save(
        &self,
        connection: Connection,
        api_key: Option<String>,
        make_default: bool,
    ) -> Result<config::Registry> {
        self.save_provider(connection, api_key, make_default, true)
    }

    fn save_provider(
        &self,
        connection: Connection,
        api_key: Option<String>,
        make_default: bool,
        requires_key: bool,
    ) -> Result<config::Registry> {
        let api_key = api_key
            .map(|key| key.trim().to_owned())
            .filter(|key| !key.is_empty());
        connection.validate()?;
        if make_default && connection.provider.category() != config::ModelCategory::Llm {
            bail!("Only an LLM provider can be the default chat provider.");
        }
        if connection.provider.is_native() && api_key.as_deref().is_some_and(|key| !key.is_empty())
        {
            bail!("Fritz local models do not use an API key.");
        }
        self.registry.update(|registry| {
            if registry
                .connections
                .iter()
                .any(|c| c.id != connection.id && c.name.eq_ignore_ascii_case(&connection.name))
            {
                bail!("A connection with that name already exists.");
            }
            if let Some(existing) = registry
                .connections
                .iter()
                .find(|c| c.id != connection.id && c.has_same_target(&connection))
            {
                if connection.provider.is_native() {
                    bail!(
                        "This local model already exists as {}. Edit that provider instead.",
                        existing.name
                    );
                }
                bail!(
                    "This provider and endpoint already exists as {}. Edit that provider instead.",
                    existing.name
                );
            }
            if let Some(old) = registry.connections.iter().find(|c| c.id == connection.id)
                && (old.provider != connection.provider || old.base_url() != connection.base_url())
                && api_key.as_deref().is_none_or(str::is_empty)
                && self.credentials.key(old.id)?.is_some()
            {
                bail!("Enter a key again when changing the provider or endpoint.");
            }
            if let Some(key) = api_key {
                self.credentials.set_key(connection.id, key.trim())?;
            }
            if requires_key
                && connection.provider.requires_key()
                && self.credentials.key(connection.id)?.is_none()
            {
                bail!("This provider requires an API key.");
            }
            if make_default
                || registry.default_connection_id.is_none()
                    && connection.provider.category() == config::ModelCategory::Llm
            {
                registry.default_connection_id = Some(connection.id);
            }
            if registry.default_connection_id == Some(connection.id)
                && connection.provider.category() != config::ModelCategory::Llm
            {
                registry.default_connection_id = registry
                    .connections
                    .iter()
                    .find(|candidate| {
                        candidate.id != connection.id
                            && candidate.provider.category() == config::ModelCategory::Llm
                    })
                    .map(|candidate| candidate.id);
            }
            if let Some(old) = registry
                .connections
                .iter_mut()
                .find(|c| c.id == connection.id)
            {
                *old = connection;
            } else {
                registry.connections.push(connection);
            }
            Ok(())
        })
    }

    fn import_providers(&self, params: &Value) -> Result<config::Registry> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct ImportItem {
            connection: Connection,
            api_key: Option<String>,
        }
        if serde_json::to_vec(params)?.len() > 1_048_576 {
            bail!("The configuration must be no larger than 1 MB.");
        }
        let items: Vec<ImportItem> = serde_json::from_value(params["providers"].clone())
            .map_err(|_| anyhow::anyhow!("Invalid provider import configuration."))?;
        // Validate the entire payload before writing any connections or credentials.
        for item in &items {
            item.connection.validate()?;
            if item.connection.provider.is_native()
                && item.api_key.as_deref().is_some_and(|key| !key.is_empty())
            {
                bail!("Fritz local models do not use an API key.");
            }
        }
        let mut registry = self.registry.load()?;
        for (count, item) in items.into_iter().enumerate() {
            registry = self
                .save_provider(item.connection, item.api_key, false, false)
                .map_err(|error| {
                    anyhow::anyhow!(
                        "Imported {count} provider(s). Could not import the next provider: {error}"
                    )
                })?;
        }
        Ok(registry)
    }

    pub fn remove(&self, id: Uuid) -> Result<config::Registry> {
        self.registry.update(|registry| {
            if !registry.connections.iter().any(|c| c.id == id) {
                bail!("Provider not found.");
            }
            if !registry
                .connections
                .iter()
                .find(|connection| connection.id == id)
                .unwrap()
                .provider
                .is_native()
            {
                self.credentials.delete_key(id)?;
            }
            registry.connections.retain(|c| c.id != id);
            if registry.default_connection_id == Some(id) {
                registry.default_connection_id = registry
                    .connections
                    .iter()
                    .find(|c| c.provider.category() == config::ModelCategory::Llm)
                    .map(|c| c.id);
            }
            Ok(())
        })
    }

    async fn discover(
        &self,
        connection: &Connection,
        supplied: Option<&str>,
    ) -> Result<Vec<provider::Model>> {
        connection.validate()?;
        if connection.provider.is_native() {
            let inventory = if connection.provider == ProviderKind::Ollaya {
                decision::local::ModelStore::new(self.decision_models.default_directory())
                    .with_model_directories(self.model_locations.load()?)
                    .inventory(None)
                    .await?
            } else {
                local::models::ModelStore::new(self.local_models.default_directory())
                    .with_model_directories(self.model_locations.load()?)
                    .inventory()
                    .await?
            };
            return Ok(inventory["models"]
                .as_array()
                .context("Invalid local model inventory")?
                .iter()
                .filter(|model| model["installed"] == true)
                .map(|model| provider::Model {
                    id: model["id"].as_str().unwrap_or_default().into(),
                    display_name: model["name"].as_str().unwrap_or_default().into(),
                })
                .collect());
        }
        let key = if let Some(key) = supplied.filter(|key| !key.is_empty()) {
            Some(key.to_owned())
        } else {
            if let Some(saved) = self
                .registry
                .load()?
                .connections
                .iter()
                .find(|saved| saved.id == connection.id)
                && !saved.has_same_target(connection)
            {
                bail!("Enter a key again when changing the provider or endpoint.");
            }
            self.credentials.key(connection.id)?
        };
        if connection.provider.requires_key() && key.is_none() {
            bail!("Add an API key for {} in Providers.", connection.name);
        }
        provider::discover_with_key(connection, key.as_deref()).await
    }

    /// None lets the host retain ownership of non-Models agent methods.
    pub async fn dispatch(
        &self,
        method: &str,
        params: &Value,
        emit: impl Fn(Value) + Sync,
    ) -> Result<Option<Value>> {
        let result: Result<Value> = match method {
            "localModels.list" | "localModels.install" => {
                let directory = download_directory(params)?;
                let store = local::models::ModelStore::new(
                    directory
                        .as_deref()
                        .unwrap_or(self.local_models.default_directory()),
                )
                .with_model_directories(if directory.is_some() {
                    Default::default()
                } else {
                    self.model_locations.load()?
                });
                if method == "localModels.install" {
                    let id = params["modelId"]
                        .as_str()
                        .context("Choose a local model.")?;
                    store.download(id, &emit).await?;
                    if let Some(directory) = directory {
                        self.model_locations.remember(id, &directory)?;
                    }
                    Ok(json!({"modelId":id,"installed":true}))
                } else {
                    match params["modelId"].as_str() {
                        Some(id) => store.inventory_model(id).await,
                        None => store.inventory().await,
                    }
                }
            }
            "decisionModels.list" | "decisionModels.install" => {
                let directory = download_directory(params)?;
                let store = decision::local::ModelStore::new(
                    directory
                        .as_deref()
                        .unwrap_or(self.decision_models.default_directory()),
                )
                .with_model_directories(if directory.is_some() {
                    Default::default()
                } else {
                    self.model_locations.load()?
                });
                if method == "decisionModels.install" {
                    let id = params["modelId"]
                        .as_str()
                        .context("Choose a local decision model.")?;
                    store.download(id, &emit).await?;
                    if let Some(directory) = directory {
                        self.model_locations.remember(id, &directory)?;
                    }
                    Ok(json!({"modelId":id,"installed":true}))
                } else {
                    store.inventory(params["modelId"].as_str()).await
                }
            }
            "providers.list" => {
                let mut registry = self.registry.load()?;
                registry.model_directories = self.model_locations.load()?;
                Ok(serde_json::to_value(registry)?)
            }
            "providers.migrationStatus" => Ok(json!({"migration": self.registry.migration_result(
            params["migrationId"].as_str().context("A migration identity is required.")?
        )?})),
            "providers.import" => Ok(serde_json::to_value(self.import_providers(params)?)?),
            "providers.migrate" => {
                if serde_json::to_vec(params)?.len() > 1_048_576 {
                    bail!("The migration must be no larger than 1 MB.");
                }
                Ok(serde_json::to_value(self.registry.migrate(
                    serde_json::from_value(params.clone())?,
                    &self.credentials,
                )?)?)
            }
            "providers.save" => Ok(serde_json::to_value(self.save(
                serde_json::from_value(params["connection"].clone())?,
                params["apiKey"].as_str().map(str::to_string),
                params["makeDefault"] == true,
            )?)?),
            "providers.remove" => Ok(serde_json::to_value(
                self.remove(serde_json::from_value(params["id"].clone())?)?,
            )?),
            "providers.default" => {
                let id: Uuid = serde_json::from_value(params["id"].clone())?;
                Ok(serde_json::to_value(self.registry.update(|registry| {
                    let connection = registry
                        .connections
                        .iter()
                        .find(|c| c.id == id)
                        .context("Provider not found.")?;
                    if connection.provider.category() != config::ModelCategory::Llm {
                        bail!("Only an LLM provider can be the default chat provider.");
                    }
                    registry.default_connection_id = Some(id);
                    Ok(())
                })?)?)
            }
            "models.list" => {
                let connection = if params["connection"].is_object() {
                    serde_json::from_value(params["connection"].clone())?
                } else {
                    self.registry.find(params["connectionId"].as_str())?
                };
                let models = self
                    .discover(&connection, params["apiKey"].as_str())
                    .await?;
                Ok(json!({"models":models}))
            }
            _ => return Ok(None),
        };
        result.map(Some)
    }
}

fn download_directory(params: &Value) -> Result<Option<std::path::PathBuf>> {
    let Some(value) = params.get("directory") else {
        return Ok(None);
    };
    let directory =
        std::path::PathBuf::from(value.as_str().context("Choose a model download folder.")?);
    if !directory.is_absolute() || (directory.exists() && !directory.is_dir()) {
        bail!("Choose an absolute folder path for the model download.");
    }
    params["modelId"]
        .as_str()
        .context("Choose a model for the download folder.")?;
    Ok(Some(directory))
}

use std::collections::HashMap;
use tokio::io::{AsyncWriteExt, BufReader};
#[derive(Deserialize)]
struct ModelsRequest {
    id: String,
    method: String,
    #[serde(default)]
    params: Value,
}

pub async fn run_stdio(service: std::sync::Arc<ModelsService>) -> Result<()> {
    let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel::<Value>();
    let writer = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(event) = receiver.recv().await {
            let mut bytes = serde_json::to_vec(&event)?;
            bytes.push(b'\n');
            stdout.write_all(&bytes).await?;
            stdout.flush().await?;
        }
        Ok::<_, anyhow::Error>(())
    });
    let mut input = BufReader::new(tokio::io::stdin());
    let mut jobs: HashMap<String, tokio::task::JoinHandle<()>> = HashMap::new();
    while let Some(line) = crate::harness_client::read_line(&mut input, 3_000_000).await? {
        jobs.retain(|_, job| !job.is_finished());
        if line.len() > 3_000_000 {
            let _ = sender.send(json!({"id":"","type":"error","message":"Request too large."}));
            continue;
        }
        let request: ModelsRequest = match serde_json::from_str(&line) {
            Ok(request) => request,
            Err(_) => {
                let _ =
                    sender.send(json!({"id":"","type":"error","message":"Invalid request JSON."}));
                continue;
            }
        };
        if jobs.contains_key(&request.id) {
            let _ = sender.send(
                json!({"id":request.id,"type":"error","message":"Request ID is already active."}),
            );
            continue;
        }
        if request.method == "cancel" {
            if let Some(target) = request.params["requestId"].as_str()
                && let Some(job) = jobs.remove(target)
            {
                job.abort();
                let _ = job.await;
                let _ = sender.send(json!({"id":target,"type":"cancelled"}));
            }
            let _ = sender.send(json!({"id":request.id,"type":"result","result":{}}));
            continue;
        }
        let tx = sender.clone();
        let service = service.clone();
        // Registry mutations finish in request order; network operations can be cancelled.
        if request.method.starts_with("providers.") {
            let result = service
                .dispatch(&request.method, &request.params, |_| {})
                .await
                .and_then(required_result);
            let _ = tx.send(envelope(&request.id, result));
        } else {
            jobs.insert(
                request.id.clone(),
                tokio::spawn(async move {
                    let result = service
                        .dispatch(&request.method, &request.params, |mut event| {
                            event["id"] = json!(request.id);
                            let _ = tx.send(event);
                        })
                        .await
                        .and_then(required_result);
                    let _ = tx.send(envelope(&request.id, result));
                }),
            );
        }
    }
    for job in jobs.values() {
        job.abort();
    }
    for (_, job) in jobs {
        let _ = job.await;
    }
    drop(sender);
    writer.await??;
    Ok(())
}

fn envelope(id: &str, result: Result<Value>) -> Value {
    match result {
        Ok(result) => json!({"id":id,"type":"result","result":result}),
        Err(error) => json!({"id":id,"type":"error","message":error.to_string()}),
    }
}

fn required_result(result: Option<Value>) -> Result<Value> {
    result.context("Unknown Models method")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::rusqlite;
    use std::{path::PathBuf, sync::Arc};

    struct HostStorage(PathBuf);
    impl config::ProviderStorage for HostStorage {
        fn open(&self) -> Result<rusqlite::Connection> {
            Ok(rusqlite::Connection::open(&self.0)?)
        }
    }

    #[tokio::test]
    async fn injected_storage_preserves_host_schema_and_persists_migration_mapping() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("host.sqlite3");
        let connection = rusqlite::Connection::open(&path).unwrap();
        connection.execute_batch("CREATE TABLE host_records (payload TEXT); INSERT INTO host_records VALUES ('keep'); PRAGMA user_version=87;").unwrap();
        connection.execute_batch(config::PROVIDER_SCHEMA).unwrap();
        connection.execute_batch("CREATE TABLE model_locations (model_id TEXT PRIMARY KEY NOT NULL, directory TEXT NOT NULL);").unwrap();
        let service = || {
            ModelsService::new(
                RegistryStore::with_storage(Arc::new(HostStorage(path.clone()))),
                CredentialStore::new("host.explicit.credentials.fixture").unwrap(),
                local::models::ModelStore::new(directory.path().join("host-models")),
                decision::local::ModelStore::new(directory.path().join("host-models")),
                config::ModelLocationStore::with_storage(Arc::new(HostStorage(path.clone()))),
            )
        };
        let saved = Connection {
            id: Uuid::new_v4(),
            name: "Existing".into(),
            provider: ProviderKind::Fritz,
            model_id: "qwen3.5-0.8b-q4_k_m".into(),
            base_url: None,
        };
        service().save(saved.clone(), None, true).unwrap();
        let source = Connection {
            id: Uuid::new_v4(),
            name: "Former".into(),
            ..saved.clone()
        };
        let request = config::migration::MigrationRequest {
            migration_id: "host-fixture".into(),
            providers: vec![config::migration::MigrationItem {
                connection: source.clone(),
                credential_source: None,
            }],
            default_connection_id: Some(source.id),
        };
        let first = service()
            .dispatch(
                "providers.migrate",
                &serde_json::to_value(request).unwrap(),
                |_| {},
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            first["connectionIds"][source.id.to_string()],
            saved.id.to_string()
        );
        // A selected download location persists in the same host database and
        // is used by inventory after restarting the service.
        let selected = directory.path().join("selected-models");
        std::fs::create_dir(&selected).unwrap();
        let selected = selected.canonicalize().unwrap();
        service()
            .model_locations
            .remember(&saved.model_id, &selected)
            .unwrap();
        let reopened = service();
        let inventory = reopened
            .dispatch(
                "localModels.list",
                &json!({"modelId":saved.model_id}),
                |_| {},
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            inventory["models"][0]["directory"],
            selected.to_str().unwrap()
        );
        let metadata = reopened
            .dispatch("providers.list", &json!({}), |_| {})
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            metadata["modelDirectories"][&saved.model_id],
            selected.to_str().unwrap()
        );
        let override_folder = directory.path().join("not-created");
        let preview = reopened
            .dispatch(
                "localModels.list",
                &json!({"modelId":saved.model_id,"directory":override_folder}),
                |_| {},
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            preview["models"][0]["directory"],
            override_folder.to_str().unwrap()
        );
        assert!(!override_folder.exists());
        assert!(
            reopened
                .dispatch(
                    "localModels.list",
                    &json!({"modelId":saved.model_id,"directory":"relative"}),
                    |_| {}
                )
                .await
                .is_err()
        );

        let status = reopened
            .dispatch(
                "providers.migrationStatus",
                &json!({"migrationId":"host-fixture"}),
                |_| {},
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(status["migration"], first);
        assert_eq!(reopened.registry.load().unwrap().connections.len(), 1);
        assert_eq!(reopened.registry.find(None).unwrap().id, saved.id);
        assert_eq!(
            connection
                .query_row("SELECT payload FROM host_records", [], |row| row
                    .get::<_, String>(0))
                .unwrap(),
            "keep"
        );
        assert_eq!(
            connection
                .query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))
                .unwrap(),
            87
        );
        assert!(!directory.path().join("providers.sqlite").exists());
        assert!(!directory.path().join("model_locations.sqlite").exists());
        assert!(!directory.path().join("host-models").exists());
    }
}
