//! Standalone Fritz's app-wide model storage and recoverable, explicit relocation.
use anyhow::{Context, Result, bail, ensure};
use fs2::FileExt;
use serde::Serialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs::{File, OpenOptions},
    path::{Path, PathBuf},
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

fn lock(path: &Path, exclusive: bool) -> Result<File> {
    std::fs::create_dir_all(path.parent().context("Missing model storage folder")?)?;
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(path)?;
    let result = if exclusive {
        file.try_lock_exclusive()
    } else {
        FileExt::try_lock_shared(&file)
    };
    result.context(
        "Model storage is in use. Finish downloads and stop affected local models, then try again.",
    )?;
    Ok(file)
}
pub fn read_settings(data: &Path) -> Result<File> {
    lock(&data.join("model-storage.lock"), false)
}
pub(crate) fn use_directory(directory: &Path) -> Result<File> {
    lock(&directory.join(".fritz-storage-use.lock"), false)
}
pub(crate) fn use_file(path: &Path) -> Result<File> {
    let file = File::open(path).context("Could not open the local model file.")?;
    FileExt::try_lock_shared(&file)
        .context("Model storage is being moved. Retry after the move finishes.")?;
    Ok(file)
}
pub fn directory(data: &Path, fallback: &Path) -> Result<PathBuf> {
    let db = crate::config::model_locations::database(data)?.into_connection();
    use crate::state::rusqlite::OptionalExtension;
    let value: Option<String> = db
        .query_row("SELECT directory FROM model_storage WHERE id=1", [], |r| {
            r.get(0)
        })
        .optional()?;
    let directory = value
        .map(PathBuf::from)
        .unwrap_or_else(|| fallback.to_owned());
    ensure!(
        directory.is_absolute(),
        "The saved model storage folder is invalid. Choose a folder in Settings."
    );
    Ok(directory)
}
#[derive(Clone)]
struct Artifact {
    id: String,
    file: String,
    size: u64,
    hash: String,
}
fn artifacts() -> Result<Vec<Artifact>> {
    let imports = crate::local::models::hugging_face::catalog()?;
    Ok(crate::local::models::catalog()
        .iter()
        .chain(imports.iter())
        .map(|p| Artifact {
            id: p.id.clone(),
            file: p.file.clone(),
            size: p.size,
            hash: p.sha256.clone(),
        })
        .chain(crate::decision::local::catalog().iter().flat_map(|p| {
            p.files.iter().map(|f| Artifact {
                id: p.id.clone(),
                file: f.file.clone(),
                size: f.size,
                hash: f.sha256.clone(),
            })
        }))
        .collect())
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Info {
    directory: PathBuf,
    model_count: usize,
    bytes: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    warning: Option<String>,
}
fn inventory(
    source: &Path,
    locations: &BTreeMap<String, PathBuf>,
    specs: &[Artifact],
) -> Result<Vec<Artifact>> {
    let mut found = Vec::new();
    for a in specs {
        let folder = locations.get(&a.id).map(PathBuf::as_path).unwrap_or(source);
        if folder.canonicalize().unwrap_or_else(|_| folder.to_owned())
            != source.canonicalize().unwrap_or_else(|_| source.to_owned())
        {
            continue;
        }
        let p = source.join(&a.file);
        match std::fs::symlink_metadata(&p) {
            Ok(m) => {
                ensure!(
                    m.is_file() && !m.file_type().is_symlink(),
                    "Model storage contains a linked or non-file model: {}",
                    a.file
                );
                found.push(a.clone());
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
        }
    }
    Ok(found)
}
fn info(data: &Path, fallback: &Path, specs: &[Artifact]) -> Result<Info> {
    let source = directory(data, fallback)?;
    let locations = crate::config::ModelLocationStore::new(data).load()?;
    let files = inventory(&source, &locations, specs)?;
    let count = files
        .iter()
        .map(|a| &a.id)
        .collect::<std::collections::BTreeSet<_>>()
        .len();
    let unique = files
        .iter()
        .map(|a| &a.file)
        .collect::<std::collections::BTreeSet<_>>();
    let bytes = unique
        .into_iter()
        .map(|f| std::fs::metadata(source.join(f)).map(|m| m.len()))
        .collect::<std::io::Result<Vec<_>>>()?
        .iter()
        .sum();
    Ok(Info {
        directory: source,
        model_count: count,
        bytes,
        warning: None,
    })
}
struct Partial(PathBuf);
impl Drop for Partial {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}
async fn verified(path: &Path, a: &Artifact) -> Result<()> {
    ensure!(
        tokio::fs::symlink_metadata(path).await?.is_file(),
        "Model is not a regular file: {}",
        a.file
    );
    let mut f = tokio::fs::File::open(path).await?;
    ensure!(
        f.metadata().await?.len() == a.size,
        "Model file size does not match: {}. The original has been kept.",
        a.file
    );
    let mut hash = Sha256::new();
    let mut buffer = vec![0; 1024 * 1024];
    loop {
        let n = f.read(&mut buffer).await?;
        if n == 0 {
            break;
        }
        hash.update(&buffer[..n]);
    }
    ensure!(
        hex::encode(hash.finalize()) == a.hash,
        "Model verification failed: {}. The original has been kept.",
        a.file
    );
    Ok(())
}
async fn change(
    data: &Path,
    fallback: &Path,
    target: &Path,
    expected: &Path,
    move_models: bool,
    specs: &[Artifact],
    emit: &(impl Fn(Value) + Sync),
) -> Result<Info> {
    ensure!(
        target.is_absolute() && target.is_dir(),
        "Choose an existing folder for model storage."
    );
    let _settings = lock(&data.join("model-storage.lock"), true)?;
    let source = directory(data, fallback)?;
    ensure!(
        source == expected,
        "Model storage changed in another window. Choose the folder again."
    );
    let target = target.canonicalize()?;
    let source = if source.exists() {
        source.canonicalize()?
    } else {
        source
    };
    if source == target {
        return info(data, fallback, specs);
    }
    ensure!(
        !target.starts_with(&source) && !source.starts_with(&target),
        "Choose a folder that is not inside, or a parent of, the current model folder."
    );
    // Test write access before presenting a successful setting change.
    let probe = target.join(format!(".fritz-write-check-{}", uuid::Uuid::new_v4()));
    let probe_guard = Partial(probe.clone());
    OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&probe)?
        .sync_all()?;
    drop(probe_guard);
    let locations = crate::config::ModelLocationStore::new(data).load()?;
    let files = inventory(&source, &locations, specs)?;
    let _source_use = if move_models && !files.is_empty() {
        Some(lock(&source.join(".fritz-storage-use.lock"), true)?)
    } else {
        None
    };
    let _target_use = if move_models && !files.is_empty() {
        Some(lock(&target.join(".fritz-storage-use.lock"), true)?)
    } else {
        None
    };
    let mut file_locks = Vec::new();
    if move_models {
        for a in &files {
            let file = File::open(source.join(&a.file))?;
            file.try_lock_exclusive()
                .context("Model storage is in use. Stop affected local models, then try again.")?;
            file_locks.push(file);
        }
    }
    let mut unique = BTreeMap::new();
    for a in &files {
        unique.entry(a.file.clone()).or_insert(a);
    }
    let total = unique.values().map(|a| a.size).sum::<u64>();
    let mut completed = 0u64;
    if move_models {
        let needed = unique
            .values()
            .filter(|a| !target.join(&a.file).exists())
            .map(|a| a.size)
            .sum::<u64>();
        ensure!(
            fs2::available_space(&target)? >= needed,
            "There isn't enough space in the selected folder to move these models."
        );
        for a in unique.values() {
            emit(
                json!({"type":"progress","completed":completed,"total":total,"file":format!("Verifying {}",a.file)}),
            );
            let from = source.join(&a.file);
            let to = target.join(&a.file);
            verified(&from, a).await?;
            if to.exists() {
                verified(&to,a).await.context("A different or incomplete model already exists in the selected folder. Choose another folder; nothing was overwritten.")?;
            } else {
                let partial = Partial(target.join(format!(
                    ".{}.{}.fritz-move.partial",
                    a.file,
                    uuid::Uuid::new_v4()
                )));
                let mut input = tokio::fs::File::open(&from).await?;
                let mut output = tokio::fs::OpenOptions::new()
                    .create_new(true)
                    .write(true)
                    .open(&partial.0)
                    .await?;
                let mut buffer = vec![0; 1024 * 1024];
                let mut copied = 0;
                loop {
                    let n = input.read(&mut buffer).await?;
                    if n == 0 {
                        break;
                    }
                    output.write_all(&buffer[..n]).await?;
                    copied += n as u64;
                    emit(
                        json!({"type":"progress","completed":completed+copied,"total":total,"file":a.file}),
                    );
                }
                output.sync_all().await?;
                drop(output);
                verified(&partial.0, a).await?;
                // Publish without overwriting any file that appeared during the copy.
                publish(&partial.0, &to)
                    .context("Could not publish the copied model; the original is unchanged.")?;
                drop(partial);
            }
            completed += a.size;
        }
    }
    if move_models && !files.is_empty() {
        File::open(&target)?.sync_all()?;
    }
    // One durable transaction publishes the preference and preserves every installed location.
    let mut db = crate::config::model_locations::database(data)?.into_connection();
    let tx =
        db.transaction_with_behavior(crate::state::rusqlite::TransactionBehavior::Immediate)?;
    tx.execute("INSERT INTO model_storage VALUES(1,?1) ON CONFLICT(id) DO UPDATE SET directory=excluded.directory",[target.to_str().context("Choose a folder with a Unicode path.")?])?;
    let ids = files
        .iter()
        .map(|a| a.id.clone())
        .collect::<std::collections::BTreeSet<_>>();
    for id in &ids {
        let folder = if move_models { &target } else { &source };
        tx.execute("INSERT INTO model_locations VALUES(?1,?2) ON CONFLICT(model_id) DO UPDATE SET directory=excluded.directory",crate::state::rusqlite::params![id,folder.to_str().context("Invalid folder path")?])?;
    }
    for (id, folder) in locations {
        if folder == source && !ids.contains(&id) {
            tx.execute("DELETE FROM model_locations WHERE model_id=?1", [id])?;
        }
    }
    tx.commit()?;
    // No await after commit: cancellation cannot interrupt metadata publication/cleanup.
    let mut cleanup_failed = false;
    if move_models {
        for file in unique.keys() {
            if std::fs::remove_file(source.join(file)).is_err() {
                cleanup_failed = true;
            }
        }
    }
    let mut result = info(data, fallback, specs)?;
    if cleanup_failed {
        result.warning=Some("Model storage changed successfully. Some original files could not be removed; copies remain in the previous folder.".into());
    }
    Ok(result)
}
#[cfg(target_os = "macos")]
fn publish(source: &Path, target: &Path) -> Result<()> {
    let source = std::ffi::CString::new(source.as_os_str().as_encoded_bytes())?;
    let target = std::ffi::CString::new(target.as_os_str().as_encoded_bytes())?;
    // Both C strings live through this synchronous call. RENAME_EXCL never replaces a destination.
    let result = unsafe { libc::renamex_np(source.as_ptr(), target.as_ptr(), libc::RENAME_EXCL) };
    if result != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(())
}
#[cfg(not(target_os = "macos"))]
fn publish(source: &Path, target: &Path) -> Result<()> {
    std::fs::hard_link(source, target)?;
    Ok(())
}

pub async fn dispatch(
    method: &str,
    params: &Value,
    emit: &(impl Fn(Value) + Sync),
) -> Result<Value> {
    let data = crate::config::data_dir();
    let fallback = crate::config::default_models_dir();
    let specs = artifacts()?;
    match method {
        "modelStorage.info" => Ok(serde_json::to_value(info(&data, &fallback, &specs)?)?),
        "modelStorage.change" => {
            let target = params["directory"]
                .as_str()
                .context("Choose a model storage folder.")?;
            let expected = params["previousDirectory"]
                .as_str()
                .context("Refresh model storage before changing it.")?;
            let moving = params["moveModels"]
                .as_bool()
                .context("Choose Move Models or Keep Existing.")?;
            Ok(serde_json::to_value(
                change(
                    &data,
                    &fallback,
                    Path::new(target),
                    Path::new(expected),
                    moving,
                    &specs,
                    emit,
                )
                .await?,
            )?)
        }
        _ => bail!("Unknown model storage request"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, PathBuf, PathBuf, PathBuf, Vec<Artifact>) {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let data = root.join("data");
        let old = root.join("old");
        let new = root.join("new");
        std::fs::create_dir(&old).unwrap();
        std::fs::create_dir(&new).unwrap();
        let bytes = b"verified model weights";
        std::fs::write(old.join("model.gguf"), bytes).unwrap();
        std::fs::write(old.join("personal.txt"), b"leave alone").unwrap();
        let specs = vec![Artifact {
            id: "model".into(),
            file: "model.gguf".into(),
            size: bytes.len() as u64,
            hash: hex::encode(Sha256::digest(bytes)),
        }];
        (temp, data, old, new, specs)
    }
    #[tokio::test]
    async fn storage_change_preserves_existing_locations_or_moves_verified_files() {
        for moving in [false, true] {
            let (_temp, data, old, new, specs) = fixture();
            let other = old.parent().unwrap().join("custom");
            std::fs::create_dir(&other).unwrap();
            let locations = crate::config::ModelLocationStore::new(&data);
            locations.remember("custom-model", &other).unwrap();
            locations.remember("missing-model", &old).unwrap();
            let before = info(&data, &old, &specs).unwrap();
            assert_eq!(before.model_count, 1);
            let result = change(&data, &old, &new, &old, moving, &specs, &|_| {})
                .await
                .unwrap();
            assert_eq!(result.directory, new);
            assert_eq!(directory(&data, &old).unwrap(), new);
            let saved = locations.load().unwrap();
            assert_eq!(
                saved["model"],
                if moving { new.clone() } else { old.clone() }
            );
            assert_eq!(saved["custom-model"], other);
            assert!(!saved.contains_key("missing-model"));
            assert_eq!(old.join("model.gguf").exists(), !moving);
            assert_eq!(new.join("model.gguf").exists(), moving);
            assert_eq!(
                std::fs::read(old.join("personal.txt")).unwrap(),
                b"leave alone"
            );
            // Durable preference survives a new database connection; a stale proposal cannot overwrite it.
            assert!(
                change(&data, &old, &old, &old, false, &specs, &|_| {})
                    .await
                    .is_err()
            );
            assert_eq!(directory(&data, &old).unwrap(), new);
        }
    }
    #[tokio::test]
    async fn relocation_rejects_conflicts_and_active_use_without_publishing() {
        for failure in ["conflict", "runtime", "download"] {
            let (_temp, data, old, new, specs) = fixture();
            let guard = match failure {
                "runtime" => Some(use_file(&old.join("model.gguf")).unwrap()),
                "download" => Some(read_settings(&data).unwrap()),
                _ => {
                    std::fs::write(new.join("model.gguf"), b"unrelated").unwrap();
                    None
                }
            };
            let error = change(&data, &old, &new, &old, true, &specs, &|_| {})
                .await
                .err()
                .unwrap();
            if failure == "conflict" {
                assert!(format!("{error:#}").contains("nothing was overwritten"));
                assert_eq!(std::fs::read(new.join("model.gguf")).unwrap(), b"unrelated");
            } else {
                assert!(format!("{error:#}").contains("in use"));
            }
            assert_eq!(directory(&data, &old).unwrap(), old);
            assert!(old.join("model.gguf").is_file());
            assert!(
                crate::config::ModelLocationStore::new(&data)
                    .load()
                    .unwrap()
                    .is_empty()
            );
            drop(guard);
        }
    }
    #[tokio::test]
    async fn interrupted_copy_keeps_originals_and_can_be_retried() {
        let (_temp, data, old, new, mut specs) = fixture();
        let bytes = vec![7u8; 8 * 1024 * 1024];
        std::fs::write(old.join("model.gguf"), &bytes).unwrap();
        specs[0].size = bytes.len() as u64;
        specs[0].hash = hex::encode(Sha256::digest(&bytes));
        let notified = std::sync::Arc::new(tokio::sync::Notify::new());
        let mut work = {
            let (data, old, new, specs, n) = (
                data.clone(),
                old.clone(),
                new.clone(),
                specs.clone(),
                notified.clone(),
            );
            tokio::spawn(async move {
                change(&data, &old, &new, &old, true, &specs, &|event| {
                    if event["file"] == "model.gguf" {
                        n.notify_one();
                    }
                })
                .await
            })
        };
        tokio::select! {
            _ = notified.notified() => {},
            result = &mut work => panic!("relocation ended before copy progress: {result:?}"),
            _ = tokio::time::sleep(std::time::Duration::from_secs(10)) => { work.abort(); panic!("relocation never began copying"); }
        }
        work.abort();
        let _ = work.await;
        assert_eq!(directory(&data, &old).unwrap(), old);
        assert_eq!(std::fs::read(old.join("model.gguf")).unwrap(), bytes);
        assert!(!std::fs::read_dir(&new).unwrap().any(|e| {
            e.unwrap()
                .file_name()
                .to_string_lossy()
                .ends_with(".fritz-move.partial")
        }));
        change(&data, &old, &new, &old, true, &specs, &|_| {})
            .await
            .unwrap();
        assert_eq!(std::fs::read(new.join("model.gguf")).unwrap(), bytes);
        assert!(!old.join("model.gguf").exists());
    }
}
