use crate::state::{Database, rusqlite::params};
use anyhow::{Context, Result, bail};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
};

fn database(directory: &Path) -> Result<Database> {
    Database::open(
        &directory.join("model_locations.sqlite"),
        &[
            "CREATE TABLE model_locations (model_id TEXT PRIMARY KEY NOT NULL, directory TEXT NOT NULL);",
        ],
        &[("model_locations", &["model_id", "directory"])],
    )
}

pub(super) fn load_from_connection(
    database: &crate::state::rusqlite::Connection,
) -> Result<BTreeMap<String, PathBuf>> {
    let records = database
        .prepare("SELECT model_id, directory FROM model_locations")?
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<crate::state::rusqlite::Result<Vec<_>>>()?;
    records
        .into_iter()
        .map(|(id, directory)| {
            let path = PathBuf::from(directory);
            if !path.is_absolute() {
                bail!("The saved model location is invalid. Choose a download folder again.");
            }
            Ok((id, path))
        })
        .collect()
}

pub(super) fn save_to_connection(
    database: &mut crate::state::rusqlite::Connection,
    model_id: &str,
    location: &Path,
) -> Result<()> {
    let location = location
        .canonicalize()
        .context("Could not resolve the model download folder.")?;
    if !location.is_dir() {
        bail!("Choose a folder for the model download.");
    }
    let location = location
        .to_str()
        .context("Choose a model folder with a valid Unicode path.")?;
    let transaction = database
        .transaction_with_behavior(crate::state::rusqlite::TransactionBehavior::Immediate)?;
    (|| -> Result<()> {
        transaction.execute("INSERT INTO model_locations VALUES (?1, ?2) ON CONFLICT(model_id) DO UPDATE SET directory = excluded.directory", params![model_id, location])?;
        transaction.commit()?;
        Ok(())
    })().context("Could not save the model download location. Retry the download to save its location.")
}

struct FritzLocationStorage(PathBuf);
impl super::ProviderStorage for FritzLocationStorage {
    fn open(&self) -> Result<crate::state::rusqlite::Connection> {
        Ok(database(&self.0)?.into_connection())
    }
}

/// Model location metadata uses a host-owned database connection when embedded.
#[derive(Clone)]
pub struct ModelLocationStore {
    storage: std::sync::Arc<dyn super::ProviderStorage>,
}
impl ModelLocationStore {
    pub fn new(directory: impl Into<PathBuf>) -> Self {
        Self::with_storage(std::sync::Arc::new(FritzLocationStorage(directory.into())))
    }
    pub fn with_storage(storage: std::sync::Arc<dyn super::ProviderStorage>) -> Self {
        Self { storage }
    }
    pub fn load(&self) -> Result<BTreeMap<String, PathBuf>> {
        load_from_connection(&self.storage.open()?)
    }
    pub fn remember(&self, model_id: &str, directory: &Path) -> Result<()> {
        save_to_connection(&mut self.storage.open()?, model_id, directory)
    }
}
