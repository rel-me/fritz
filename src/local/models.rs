//! The app ships the inference runtime and manifest, but downloads weights only
//! after an explicit install request in provider setup. This cache belongs to the selected runtime.
use anyhow::{Result, anyhow};
use fs2::FileExt;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    time::Instant,
};
use std::{
    io::Write,
    path::{Path, PathBuf},
    time::Duration,
};
use tokio::io::AsyncReadExt;

#[derive(Debug, Deserialize)]
pub(crate) struct Manifest {
    pub id: String,
    pub name: String,
    pub disable_thinking: bool,
    file: String,
    repository: String,
    revision: String,
    size: u64,
    sha256: String,
}

pub(crate) fn catalog() -> &'static [Manifest] {
    #[derive(Deserialize)]
    struct Catalog {
        models: Vec<Manifest>,
    }
    static CATALOG: std::sync::OnceLock<Vec<Manifest>> = std::sync::OnceLock::new();
    CATALOG.get_or_init(|| {
        serde_json::from_str::<Catalog>(include_str!("../../app/Sources/Fritz/LocalModels.json"))
            .expect("checked-in local model catalog")
            .models
    })
}

pub(crate) fn manifest(id: &str) -> Result<&'static Manifest> {
    catalog()
        .iter()
        .find(|model| model.id == id)
        .ok_or_else(|| anyhow!("Unknown Fritz local model: {id}"))
}

fn directory(pin: &Manifest) -> PathBuf {
    cache_directory(&crate::config::data_dir(), pin)
}

fn cache_directory(data: &Path, pin: &Manifest) -> PathBuf {
    data.join("Models").join(&pin.id)
}

async fn verified(path: &Path, pin: &Manifest) -> bool {
    let Ok(mut file) = tokio::fs::File::open(path).await else {
        return false;
    };
    if file.metadata().await.map(|m| m.len()).ok() != Some(pin.size) {
        return false;
    }
    let mut hash = Sha256::new();
    let mut buffer = vec![0; 1024 * 1024];
    loop {
        match file.read(&mut buffer).await {
            Ok(0) => break,
            Ok(count) => hash.update(&buffer[..count]),
            Err(_) => return false,
        }
    }
    format!("{:x}", hash.finalize()) == pin.sha256
}

pub(crate) async fn installed_path(model_id: &str) -> Result<PathBuf> {
    let pin = manifest(model_id)?;
    let path = directory(pin).join(&pin.file);
    if verified(&path, pin).await {
        Ok(path)
    } else {
        Err(anyhow!(format!(
            "{} is not installed. Open Providers → New Provider → Local → Fritz to download and install it.",
            pin.name
        )))
    }
}

fn progress(emit: &(impl Fn(Value) + Sync), downloaded: u64, total: u64, status: &str) {
    emit(json!({"type":"progress","downloaded":downloaded,"total":total,"status":status}));
}

// A killed agent can leave at most this one bounded partial file. The kernel
// releases its lock; the next explicit attempt truncates it. It is never loaded.
struct Partial(PathBuf);
impl Drop for Partial {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

pub async fn download(model_id: &str, emit: &(impl Fn(Value) + Sync)) -> Result<()> {
    let pin = manifest(model_id)?;
    let url = format!(
        "https://huggingface.co/{}/resolve/{}/{}",
        pin.repository, pin.revision, pin.file
    );
    download_to(&directory(pin), &url, pin, emit).await
}

async fn download_to(
    directory: &Path,
    url: &str,
    pin: &Manifest,
    emit: &(impl Fn(Value) + Sync),
) -> Result<()> {
    fs::create_dir_all(directory)?;
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(directory.join("download.lock"))?;
    lock.try_lock_exclusive().map_err(|_| {
        anyhow!(
            "This model is being installed in another window. Retry when that download finishes.",
        )
    })?;
    let destination = directory.join(&pin.file);
    progress(emit, 0, pin.size, "checking");
    if verified(&destination, pin).await {
        progress(emit, pin.size, pin.size, "ready");
        return Ok(());
    }
    let partial = Partial(directory.join("model.partial"));
    let mut file = File::create(&partial.0)?;
    let client = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(30))
        .read_timeout(Duration::from_secs(60))
        .timeout(Duration::from_secs(1800))
        .https_only(!cfg!(test))
        .build()
        .map_err(|_| anyhow!("Cannot initialize model download."))?;
    progress(emit, 0, pin.size, "downloading");
    let mut response = client.get(url).send().await.map_err(|_| {
        anyhow!("Model download could not connect. Check your connection and retry.",)
    })?;
    if !response.status().is_success() {
        return Err(anyhow!(format!(
            "Model download returned HTTP {}. Retry later.",
            response.status().as_u16()
        )));
    }
    if response
        .content_length()
        .is_some_and(|length| length != pin.size)
    {
        return Err(anyhow!(
            "Model download has an unexpected size. No model was installed.",
        ));
    }
    let mut received = 0u64;
    let mut hash = Sha256::new();
    let mut last = Instant::now();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| anyhow!("Model download was interrupted. Check your connection and retry.",))?
    {
        received = received.saturating_add(chunk.len() as u64);
        if received > pin.size {
            return Err(anyhow!("Model download exceeded its expected size.",));
        }
        file.write_all(&chunk)?;
        hash.update(&chunk);
        if last.elapsed() >= Duration::from_millis(150) {
            progress(emit, received, pin.size, "downloading");
            last = Instant::now();
        }
    }
    progress(emit, received, pin.size, "checking");
    if received != pin.size || format!("{:x}", hash.finalize()) != pin.sha256 {
        return Err(anyhow!(
            "Model download failed size or SHA-256 verification. Retry to download a fresh copy.",
        ));
    }
    file.sync_all()?;
    drop(file);
    fs::rename(&partial.0, destination)?;
    progress(emit, pin.size, pin.size, "ready");
    Ok(())
}

#[cfg(test)]
const MODEL_ID: &str = "qwen2.5-1.5b-instruct-q4_k_m";
pub async fn inventory() -> Result<Value> {
    inventory_for(catalog().iter()).await
}

pub async fn inventory_model(id: &str) -> Result<Value> {
    inventory_for(std::iter::once(manifest(id)?)).await
}

async fn inventory_for<'a>(pins: impl Iterator<Item = &'a Manifest>) -> Result<Value> {
    let mut models = Vec::new();
    for pin in pins {
        let path = directory(pin).join(&pin.file);
        models.push(json!({"id":pin.id,"name":pin.name,"size":pin.size,"installed":verified(&path,pin).await}));
    }
    Ok(json!({"models":models}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{io::Read, net::TcpListener, sync::Mutex};

    #[test]
    fn catalog_pins_are_complete_unique_and_confined_to_model_directories() {
        let mut ids = std::collections::HashSet::new();
        let mut paths = std::collections::HashSet::new();
        for pin in catalog() {
            assert!(ids.insert(&pin.id));
            assert!(
                pin.id
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || b".-_".contains(&c))
            );
            assert_eq!(pin.revision.len(), 40);
            assert!(pin.revision.bytes().all(|c| c.is_ascii_hexdigit()));
            assert_eq!(pin.sha256.len(), 64);
            assert!(pin.sha256.bytes().all(|c| c.is_ascii_hexdigit()));
            assert_eq!(Path::new(&pin.file).components().count(), 1);
            assert!(pin.size > 0);
            assert!(paths.insert(cache_directory(Path::new("data"), pin)));
        }
        assert!(manifest("../../outside").is_err());
        assert!(manifest("unknown").is_err());
    }

    #[tokio::test]
    async fn installing_models_keeps_weights_and_locks_independent() {
        let temp = tempfile::tempdir().unwrap();
        let data = b"fixture model";
        for id in [MODEL_ID, "second-model"] {
            let pin = Manifest {
                id: id.into(),
                name: id.into(),
                disable_thinking: false,
                file: "model.gguf".into(),
                repository: String::new(),
                revision: String::new(),
                size: data.len() as u64,
                sha256: format!("{:x}", Sha256::digest(data)),
            };
            let directory = cache_directory(temp.path(), &pin);
            let (url, server) = fixture(data);
            download_to(&directory, &url, &pin, &|_| {}).await.unwrap();
            server.join().unwrap();
            assert!(verified(&directory.join(&pin.file), &pin).await);
        }
        assert!(
            temp.path()
                .join("Models/qwen2.5-1.5b-instruct-q4_k_m/model.gguf")
                .exists()
        );
        assert!(temp.path().join("Models/second-model/model.gguf").exists());
    }
    fn fixture(data: &'static [u8]) -> (String, std::thread::JoinHandle<()>) {
        fixture_response(data, 200, data.len() as u64)
    }
    fn fixture_response(
        data: &'static [u8],
        status: u16,
        size: u64,
    ) -> (String, std::thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let thread = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let _ = stream.read(&mut [0; 8192]);
            write!(
                stream,
                "HTTP/1.1 {status} Status\r\nContent-Length: {size}\r\nConnection: close\r\n\r\n"
            )
            .unwrap();
            stream.write_all(data).unwrap();
        });
        (url, thread)
    }

    #[tokio::test]
    async fn failed_downloads_never_publish_partial_weights() {
        let temp = tempfile::tempdir().unwrap();
        let data = b"fixture model";
        let pin = Manifest {
            id: "fixture".into(),
            name: "Fixture".into(),
            disable_thinking: false,
            file: "model.gguf".into(),
            repository: String::new(),
            revision: String::new(),
            size: data.len() as u64,
            sha256: format!("{:x}", Sha256::digest(data)),
        };
        for (body, status, size) in [
            (data.as_slice(), 404, pin.size),
            (data.as_slice(), 200, pin.size + 1),
            (b"short".as_slice(), 200, pin.size),
        ] {
            let (url, server) = fixture_response(body, status, size);
            assert!(download_to(temp.path(), &url, &pin, &|_| {}).await.is_err());
            server.join().unwrap();
            assert!(!temp.path().join(&pin.file).exists());
            assert!(!temp.path().join("model.partial").exists());
        }
    }

    #[tokio::test]
    async fn cancellation_cleans_partial_and_releases_install_lock() {
        let temp = tempfile::tempdir().unwrap();
        let data = b"fixture model";
        let pin = Manifest {
            id: "fixture".into(),
            name: "Fixture".into(),
            disable_thinking: false,
            file: "model.gguf".into(),
            repository: String::new(),
            revision: String::new(),
            size: data.len() as u64,
            sha256: format!("{:x}", Sha256::digest(data)),
        };
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let (ready, received) = tokio::sync::oneshot::channel();
        let (release, hold) = std::sync::mpsc::channel::<()>();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let _ = stream.read(&mut [0; 8192]);
            write!(stream, "HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nf").unwrap();
            ready.send(()).unwrap();
            let _ = hold.recv_timeout(Duration::from_secs(5));
        });
        let mut download = Box::pin(download_to(temp.path(), &url, &pin, &|_| {}));
        tokio::select! {
            result = &mut download => panic!("download finished early: {result:?}"),
            _ = received => {},
        }
        assert!(temp.path().join("model.partial").exists());
        drop(download);
        release.send(()).unwrap();
        server.join().unwrap();
        assert!(!temp.path().join("model.partial").exists());
        assert!(!temp.path().join(&pin.file).exists());
        let (url, server) = fixture(data);
        download_to(temp.path(), &url, &pin, &|_| {}).await.unwrap();
        server.join().unwrap();
        assert!(verified(&temp.path().join(&pin.file), &pin).await);
    }
    #[tokio::test]
    async fn download_verifies_atomic_install_and_reuses_offline() {
        let temp = tempfile::tempdir().unwrap();
        let data = b"fixture model";
        let pin = Manifest {
            id: "fixture".into(),
            name: "Fixture".into(),
            disable_thinking: false,
            file: "fixture.gguf".into(),
            repository: String::new(),
            revision: String::new(),
            size: data.len() as u64,
            sha256: format!("{:x}", Sha256::digest(data)),
        };
        let (url, server) = fixture(data);
        let events = Mutex::new(Vec::new());
        download_to(temp.path(), &url, &pin, &|event| {
            events.lock().unwrap().push(event)
        })
        .await
        .unwrap();
        server.join().unwrap();
        assert!(verified(&temp.path().join(&pin.file), &pin).await);
        assert!(!temp.path().join("model.partial").exists());
        assert!(
            events
                .lock()
                .unwrap()
                .iter()
                .any(|event| event["status"] == "ready")
        );
        download_to(temp.path(), "http://127.0.0.1:1", &pin, &|_| {})
            .await
            .unwrap();
        fs::write(temp.path().join(&pin.file), b"corrupt model").unwrap();
        let (url, server) = fixture(b"wrong weights");
        assert!(download_to(temp.path(), &url, &pin, &|_| {}).await.is_err());
        server.join().unwrap();
        assert!(!verified(&temp.path().join(&pin.file), &pin).await);
        assert!(!temp.path().join("model.partial").exists());
        let lock = File::create(temp.path().join("download.lock")).unwrap();
        lock.lock_exclusive().unwrap();
        assert!(
            download_to(temp.path(), "http://127.0.0.1:1", &pin, &|_| {})
                .await
                .unwrap_err()
                .to_string()
                .contains("another window")
        );
    }
}
