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

pub(super) fn load(directory: &Path) -> Result<BTreeMap<String, PathBuf>> {
    if !directory.join("model_locations.sqlite").exists() {
        return Ok(BTreeMap::new());
    }
    let database = database(directory)?;
    let records = database
        .connection()
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

pub(super) fn save(directory: &Path, model_id: &str, location: &Path) -> Result<()> {
    let location = location
        .canonicalize()
        .context("Could not resolve the model download folder.")?;
    if !location.is_dir() {
        bail!("Choose a folder for the model download.");
    }
    let location = location
        .to_str()
        .context("Choose a model folder with a valid Unicode path.")?;
    database(directory)?.transaction(|transaction| {
        transaction.execute("INSERT INTO model_locations VALUES (?1, ?2) ON CONFLICT(model_id) DO UPDATE SET directory = excluded.directory", params![model_id, location])?;
        Ok(())
    }).context("Could not save the model download location. Retry the download to save its location.")
}
