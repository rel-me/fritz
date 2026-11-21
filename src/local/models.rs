//! The app ships the inference runtime and manifest, but downloads weights only
//! after an explicit install request in provider setup. Debug apps share model storage across checkouts.
use anyhow::{Context, Result, anyhow};
use fs2::FileExt;
use futures_util::StreamExt;
use reqwest::{
    StatusCode,
    header::{ACCEPT_ENCODING, CONTENT_RANGE, RANGE},
};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    os::unix::fs::OpenOptionsExt,
};
use std::{
    io::{Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

use tokio::io::AsyncReadExt;

#[derive(Debug, Deserialize)]
pub struct Manifest {
    pub id: String,
    pub name: String,
    pub disable_thinking: bool,
    pub architecture: String,
    pub(crate) quantization: Option<String>,
    pub(crate) file: String,
    repository: String,
    revision: String,
    pub size: u64,
    pub sha256: String,
}

pub fn catalog() -> &'static [Manifest] {
    #[derive(Deserialize)]
    struct Catalog {
        models: Vec<Manifest>,
    }
    static CATALOG: std::sync::OnceLock<Vec<Manifest>> = std::sync::OnceLock::new();
    CATALOG.get_or_init(|| {
        serde_json::from_str::<Catalog>(include_str!("../../Sources/Fritz/LocalModels.json"))
            .expect("checked-in local model catalog")
            .models
    })
}

pub fn manifest(id: &str) -> Result<&'static Manifest> {
    catalog()
        .iter()
        .find(|model| model.id == id)
        .ok_or_else(|| anyhow!("Unknown Fritz local model: {id}"))
}

/// Flat model files in a host-selected Models directory. Downloads verify before publication.
#[derive(Clone, Debug)]
pub struct ModelStore {
    directory: PathBuf,
    model_directories: std::collections::BTreeMap<String, PathBuf>,
}

impl ModelStore {
    pub fn new(directory: impl Into<PathBuf>) -> Self {
        Self {
            directory: directory.into(),
            model_directories: Default::default(),
        }
    }

    pub fn with_model_directories(
        mut self,
        directories: std::collections::BTreeMap<String, PathBuf>,
    ) -> Self {
        self.model_directories = directories;
        self
    }

    pub fn default_directory(&self) -> &std::path::Path {
        &self.directory
    }

    pub fn configured() -> Result<Self> {
        Ok(Self {
            directory: crate::config::models_dir()?,
            model_directories: crate::config::model_directories()?,
        })
    }

    pub(crate) fn directory_for(&self, model_id: &str) -> &Path {
        self.model_directories
            .get(model_id)
            .map(PathBuf::as_path)
            .unwrap_or(&self.directory)
    }

    pub async fn installed_path(&self, model_id: &str) -> Result<PathBuf> {
        let pin = manifest(model_id)?;
        let path = self.directory_for(model_id).join(&pin.file);
        if path.is_file() {
            Ok(path)
        } else {
            Err(anyhow!(format!(
                "{} is not installed. Choose it in the chat model picker or open Models → Local Models to download it.",
                pin.name
            )))
        }
    }
}

fn progress(emit: &(impl Fn(Value) + Sync), downloaded: u64, total: u64, status: &str) {
    emit(json!({"type":"progress","downloaded":downloaded,"total":total,"status":status}));
}

pub async fn download(model_id: &str, emit: &(impl Fn(Value) + Sync)) -> Result<()> {
    ModelStore::configured()?.download(model_id, emit).await
}

impl ModelStore {
    pub async fn download(&self, model_id: &str, emit: &(impl Fn(Value) + Sync)) -> Result<()> {
        let pin = manifest(model_id)?;
        let url = format!(
            "https://huggingface.co/{}/resolve/{}/{}",
            pin.repository, pin.revision, pin.file
        );
        download_to(self.directory_for(model_id), &url, pin, emit).await
    }
}

async fn download_to(
    directory: &Path,
    url: &str,
    pin: &Manifest,
    emit: &(impl Fn(Value) + Sync),
) -> Result<()> {
    download_file(directory, url, &pin.file, pin.size, &pin.sha256, emit).await
}

pub(crate) async fn download_file(
    directory: &Path,
    url: &str,
    filename: &str,
    size: u64,
    sha256: &str,
    emit: &(impl Fn(Value) + Sync),
) -> Result<()> {
    let destination = directory.join(filename);
    progress(emit, 0, size, "checking");
    if destination.is_file() {
        progress(emit, size, size, "ready");
        return Ok(());
    }
    fs::create_dir_all(directory).with_context(|| format!(
        "Could not create model storage at {}. Create this directory and grant your account write access.", directory.display()
    ))?;
    let _storage_use = crate::model_storage::use_directory(directory)?;
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(directory.join(format!(".{filename}.download.lock")))
        .with_context(|| {
            format!(
                "Could not write model storage at {}. Grant your account write access.",
                directory.display()
            )
        })?;
    lock.try_lock_exclusive().map_err(|_| {
        anyhow!(
            "This model is being installed in another window. Retry when that download finishes."
        )
    })?;
    if destination.is_file() {
        progress(emit, size, size, "ready");
        return Ok(());
    }
    let partial = directory.join(format!(".{filename}.partial"));
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&partial)
        .context("Could not open the partial model download.")?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(anyhow!("The partial model download is not a regular file."));
    }
    let mut received = metadata.len();
    if received > size {
        file.set_len(0)?;
        received = 0;
    }

    let mut hash = Sha256::new();
    if received > 0 {
        hash_prefix(&file, received, &mut hash).await?;
    }
    if received < size {
        let client = reqwest::Client::builder()
            .user_agent(concat!("Fritz/", env!("CARGO_PKG_VERSION")))
            .connect_timeout(Duration::from_secs(30))
            .read_timeout(Duration::from_secs(60))
            .https_only(!cfg!(test))
            .build()
            .map_err(|_| anyhow!("Cannot initialize model download."))?;
        let mut request = client.get(url).header(ACCEPT_ENCODING, "identity");
        if received > 0 {
            request = request.header(RANGE, format!("bytes={received}-"));
        }
        let response = request.send().await.map_err(|_| {
            anyhow!("Model download could not connect. Check your connection and retry.")
        })?;
        match response.status() {
            StatusCode::OK => received = 0,
            StatusCode::PARTIAL_CONTENT if received > 0 => {
                let expected = format!("bytes {received}-{}/{size}", size - 1);
                if response
                    .headers()
                    .get(CONTENT_RANGE)
                    .and_then(|range| range.to_str().ok())
                    != Some(expected.as_str())
                {
                    return Err(anyhow!(
                        "Model server sent an unexpected byte range. Retry later."
                    ));
                }
            }
            status => {
                return Err(anyhow!(
                    "Model download returned HTTP {}. Retry later.",
                    status.as_u16()
                ));
            }
        }
        if response
            .content_length()
            .is_some_and(|length| length != size - received)
        {
            return Err(anyhow!(
                "Model download has an unexpected size. No model was installed."
            ));
        }

        if received == 0 {
            // A server may ignore Range. Validate its full response before replacing the prefix.
            file.set_len(0)?;
            hash = Sha256::new();
        }
        file.seek(SeekFrom::Start(received))?;
        progress(emit, received, size, "downloading");
        let mut body = response.bytes_stream();
        let sample_period = Duration::from_secs(1);
        let mut sampled_at = Instant::now();
        let mut sampled_bytes = received;
        let mut rate = 0.0;
        let mut samples =
            tokio::time::interval_at(tokio::time::Instant::now() + sample_period, sample_period);
        samples.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tokio::select! {
                chunk = body.next() => {
                    let Some(chunk) = chunk else { break };
                    let chunk = chunk.map_err(|_| anyhow!("Model download was interrupted. Retry to resume."))?;
                    received = received.saturating_add(chunk.len() as u64);
                    if received > size {
                        drop(file);
                        fs::remove_file(&partial)?;
                        return Err(anyhow!("Model download exceeded its expected size. Retry to download a fresh copy."));
                    }
                    file.write_all(&chunk)?;
                    hash.update(&chunk);
                }
                _ = samples.tick() => {
                    let now = Instant::now();
                    let measured = (received - sampled_bytes) as f64 / now.duration_since(sampled_at).as_secs_f64();
                    rate = if measured == 0.0 || rate == 0.0 { measured } else { 0.7 * rate + 0.3 * measured };
                    let bytes_per_second = (rate.round() as u64).max(u64::from(rate > 0.0));
                    emit(json!({"type":"progress","downloaded":received,"total":size,"status":"downloading",
                        "bytesPerSecond":bytes_per_second}));
                    sampled_at = now;
                    sampled_bytes = received;
                }
            }
        }
    }
    if received != size {
        return Err(anyhow!("Model download was interrupted. Retry to resume."));
    }
    progress(emit, received, size, "checking");
    if format!("{:x}", hash.finalize()) != sha256 {
        drop(file);
        fs::remove_file(&partial)?;
        return Err(anyhow!(
            "Model download failed SHA-256 verification. Retry to download a fresh copy."
        ));
    }
    file.sync_all()?;
    drop(file);
    fs::rename(&partial, destination)?;
    progress(emit, size, size, "ready");
    Ok(())
}

// Hash persisted bytes as well as new bytes before publishing any model.
async fn hash_prefix(file: &File, size: u64, hash: &mut Sha256) -> Result<()> {
    let mut reader = tokio::fs::File::from_std(file.try_clone()?).take(size);
    let mut buffer = vec![0; 1024 * 1024];
    while reader.limit() > 0 {
        let count = reader.read(&mut buffer).await?;
        if count == 0 {
            return Err(anyhow!(
                "The partial download changed while being read. Retry the download."
            ));
        }
        hash.update(&buffer[..count]);
    }
    Ok(())
}

#[cfg(test)]
const MODEL_ID: &str = "qwen2.5-1.5b-instruct-q4_k_m";
pub async fn inventory() -> Result<Value> {
    ModelStore::configured()?.inventory().await
}

pub async fn inventory_model(id: &str) -> Result<Value> {
    ModelStore::configured()?.inventory_model(id).await
}

impl ModelStore {
    pub async fn inventory(&self) -> Result<Value> {
        self.inventory_for(catalog().iter()).await
    }

    pub async fn inventory_model(&self, id: &str) -> Result<Value> {
        self.inventory_for(std::iter::once(manifest(id)?)).await
    }

    async fn inventory_for<'a>(&self, pins: impl Iterator<Item = &'a Manifest>) -> Result<Value> {
        let mut models = Vec::new();
        for pin in pins {
            let directory = self.directory_for(&pin.id);
            let path = directory.join(&pin.file);
            let installed = path.is_file();
            models.push(
                json!({"id":pin.id,"name":pin.name,"size":pin.size,"installed":installed,
                    "path":installed.then_some(path), "directory":directory}),
            );
        }
        Ok(json!({"models":models}))
    }
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
            assert!(paths.insert(&pin.file));
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
                architecture: String::new(),
                quantization: None,
                file: format!("{id}.gguf"),
                repository: String::new(),
                revision: String::new(),
                size: data.len() as u64,
                sha256: format!("{:x}", Sha256::digest(data)),
            };
            let directory = temp.path();
            let _other_lock = if id == "second-model" {
                let file =
                    File::open(directory.join(format!(".{MODEL_ID}.gguf.download.lock"))).unwrap();
                file.lock_exclusive().unwrap();
                Some(file)
            } else {
                None
            };
            let (url, server) = fixture(data);
            download_to(directory, &url, &pin, &|_| {}).await.unwrap();
            server.join().unwrap();
            assert_eq!(fs::read(directory.join(&pin.file)).unwrap(), data);
        }
        assert!(
            temp.path()
                .join("qwen2.5-1.5b-instruct-q4_k_m.gguf")
                .exists()
        );
        assert!(temp.path().join("second-model.gguf").exists());
    }
    fn fixture(data: &'static [u8]) -> (String, std::thread::JoinHandle<()>) {
        fixture_response(data, 200, data.len() as u64, None, None)
    }
    fn fixture_response(
        data: &'static [u8],
        status: u16,
        size: u64,
        requested_range: Option<&'static str>,
        content_range: Option<&'static str>,
    ) -> (String, std::thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let thread = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = String::new();
            let mut reader = std::io::BufReader::new(&stream);
            use std::io::BufRead;
            loop {
                let mut line = String::new();
                assert_ne!(reader.read_line(&mut line).unwrap(), 0);
                if line == "\r\n" {
                    break;
                }
                request.push_str(&line);
            }
            assert_eq!(
                request
                    .lines()
                    .find_map(|line| line.strip_prefix("range: ")),
                requested_range
            );
            write!(
                stream,
                "HTTP/1.1 {status} Status\r\nContent-Length: {size}\r\nConnection: close\r\n"
            )
            .unwrap();
            if let Some(range) = content_range {
                write!(stream, "Content-Range: {range}\r\n").unwrap();
            }
            write!(stream, "\r\n").unwrap();
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
            architecture: String::new(),
            quantization: None,
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
            let (url, server) = fixture_response(body, status, size, None, None);
            assert!(download_to(temp.path(), &url, &pin, &|_| {}).await.is_err());
            server.join().unwrap();
            assert!(!temp.path().join(&pin.file).exists());
        }
        let partial = temp.path().join(format!(".{}.partial", pin.file));
        assert_eq!(fs::read(&partial).unwrap(), b"short");
        // A full response to a resume request replaces the prefix instead of appending.
        let (url, server) = fixture_response(data, 200, pin.size, Some("bytes=5-"), None);
        download_to(temp.path(), &url, &pin, &|_| {}).await.unwrap();
        server.join().unwrap();
        assert_eq!(fs::read(temp.path().join(&pin.file)).unwrap(), data);
        assert!(!partial.exists());
    }

    #[tokio::test]
    async fn cancellation_retains_download_and_retry_resumes_from_saved_bytes() {
        let temp = tempfile::tempdir().unwrap();
        let data = b"fixture model";
        let pin = Manifest {
            id: "fixture".into(),
            name: "Fixture".into(),
            disable_thinking: false,
            architecture: String::new(),
            quantization: None,
            file: "model.gguf".into(),
            repository: String::new(),
            revision: String::new(),
            size: data.len() as u64,
            sha256: format!("{:x}", Sha256::digest(data)),
        };
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let (progress_tx, mut progress_rx) = tokio::sync::mpsc::unbounded_channel();
        let (release, hold) = std::sync::mpsc::channel::<()>();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let _ = stream.read(&mut [0; 8192]);
            write!(stream, "HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nf").unwrap();
            let _ = hold.recv_timeout(Duration::from_secs(10));
        });
        let emit = |event: Value| {
            if event["bytesPerSecond"]
                .as_u64()
                .is_some_and(|rate| rate > 0)
            {
                progress_tx.send(event).unwrap();
            }
        };
        let mut download = Box::pin(download_to(temp.path(), &url, &pin, &emit));
        tokio::select! {
            result = &mut download => panic!("download finished early: {result:?}"),
            event = progress_rx.recv() => assert_eq!(event.unwrap()["downloaded"], 1),
        }
        drop(download);
        release.send(()).unwrap();
        server.join().unwrap();
        let partial = temp.path().join(format!(".{}.partial", pin.file));
        assert_eq!(fs::read(&partial).unwrap(), b"f");
        assert!(!temp.path().join(&pin.file).exists());

        let (url, server) =
            fixture_response(&data[1..], 206, 12, Some("bytes=1-"), Some("bytes 0-11/13"));
        assert!(download_to(temp.path(), &url, &pin, &|_| {}).await.is_err());
        server.join().unwrap();
        assert_eq!(fs::read(&partial).unwrap(), b"f");

        let (url, server) =
            fixture_response(&data[1..], 206, 12, Some("bytes=1-"), Some("bytes 1-12/13"));
        let events = Mutex::new(Vec::new());
        download_to(temp.path(), &url, &pin, &|event| {
            events.lock().unwrap().push(event)
        })
        .await
        .unwrap();
        server.join().unwrap();
        let events = events.into_inner().unwrap();
        let first_transfer = events
            .iter()
            .find(|event| event["status"] == "downloading")
            .unwrap();
        assert_eq!(first_transfer["downloaded"], 1);
        assert!(first_transfer["bytesPerSecond"].is_null());
        assert!(!partial.exists());
        assert_eq!(fs::read(temp.path().join(&pin.file)).unwrap(), data);
    }
    #[tokio::test]
    async fn download_verifies_atomic_install_and_reuses_offline() {
        let temp = tempfile::tempdir().unwrap();
        let directory = temp.path().join("Models");
        assert!(!directory.exists());
        let data = b"fixture model";
        let pin = Manifest {
            id: "fixture".into(),
            name: "Fixture".into(),
            disable_thinking: false,
            architecture: String::new(),
            quantization: None,
            file: "fixture.gguf".into(),
            repository: String::new(),
            revision: String::new(),
            size: data.len() as u64,
            sha256: format!("{:x}", Sha256::digest(data)),
        };
        let (url, server) = fixture(data);
        let events = Mutex::new(Vec::new());
        download_to(&directory, &url, &pin, &|event| {
            events.lock().unwrap().push(event)
        })
        .await
        .unwrap();
        server.join().unwrap();
        assert_eq!(fs::read(directory.join(&pin.file)).unwrap(), data);
        assert!(!directory.join(format!(".{}.partial", pin.file)).exists());
        assert!(
            events
                .lock()
                .unwrap()
                .iter()
                .any(|event| event["status"] == "ready")
        );
        download_to(&directory, "http://127.0.0.1:1", &pin, &|_| {})
            .await
            .unwrap();
        fs::write(directory.join(&pin.file), b"host-provided weights").unwrap();
        download_to(&directory, "http://127.0.0.1:1", &pin, &|_| {})
            .await
            .unwrap();
        assert_eq!(
            fs::read(directory.join(&pin.file)).unwrap(),
            b"host-provided weights"
        );
        fs::remove_file(directory.join(&pin.file)).unwrap();
        let (url, server) = fixture(b"wrong weights");
        assert!(download_to(&directory, &url, &pin, &|_| {}).await.is_err());
        server.join().unwrap();
        assert!(!directory.join(&pin.file).exists());
        assert!(!directory.join(format!(".{}.partial", pin.file)).exists());
        let lock = File::create(directory.join(format!(".{}.download.lock", pin.file))).unwrap();
        lock.lock_exclusive().unwrap();
        assert!(
            download_to(&directory, "http://127.0.0.1:1", &pin, &|_| {})
                .await
                .unwrap_err()
                .to_string()
                .contains("another window")
        );
    }
}
