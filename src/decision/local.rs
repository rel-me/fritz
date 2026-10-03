//! Ollaya inference runs only in the private decision harness. Installation is explicit.
use super::{DecisionFuture, DecisionModel, DecisionRequest, DecisionResponse, Usage};
use crate::local::models::download_file;
use anyhow::{Context, Result, bail};
use ollaya_runner::{Device, Encoding, ModelFiles, OnnxModel};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{collections::BTreeMap, path::PathBuf};

#[derive(Deserialize)]
pub struct Manifest {
    pub id: String,
    pub name: String,
    pub size: u64,
    revision: String,
    files: Vec<ModelFile>,
}

#[derive(Deserialize)]
struct ModelFile {
    file: String,
    url: String,
    size: u64,
    sha256: String,
}

pub fn catalog() -> &'static [Manifest] {
    #[derive(Deserialize)]
    struct Catalog {
        models: Vec<Manifest>,
    }
    static CATALOG: std::sync::OnceLock<Vec<Manifest>> = std::sync::OnceLock::new();
    CATALOG.get_or_init(|| {
        serde_json::from_str::<Catalog>(include_str!("../../Sources/Fritz/DecisionModels.json"))
            .expect("checked-in decision model catalog")
            .models
    })
}

pub fn manifest(id: &str) -> Result<&'static Manifest> {
    catalog()
        .iter()
        .find(|pin| pin.id == id)
        .with_context(|| format!("Unknown local decision model: {id}"))
}

/// Decision artifacts share the host-selected Models directory with chat weights.
pub struct ModelStore {
    directory: PathBuf,
    model_directories: BTreeMap<String, PathBuf>,
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
            directory: crate::config::models_dir(),
            model_directories: crate::config::model_directories()?,
        })
    }

    fn directory_for(&self, model_id: &str) -> &std::path::Path {
        self.model_directories
            .get(model_id)
            .map(PathBuf::as_path)
            .unwrap_or(&self.directory)
    }

    async fn is_installed(&self, pin: &Manifest) -> bool {
        for file in &pin.files {
            if !self.directory_for(&pin.id).join(&file.file).is_file() {
                return false;
            }
        }
        true
    }

    pub async fn installed_path(&self, id: &str) -> Result<PathBuf> {
        let pin = manifest(id)?;
        if !self.is_installed(pin).await {
            bail!(
                "{} is not installed. Download it in Models → + → Provider → Ollaya, or run `fritz decision-models install {id}`.",
                pin.name
            );
        }
        Ok(self.directory_for(id).to_owned())
    }

    pub async fn inventory(&self, id: Option<&str>) -> Result<Value> {
        let pins = match id {
            Some(id) => vec![manifest(id)?],
            None => catalog().iter().collect(),
        };
        let mut models = Vec::new();
        for pin in pins {
            let installed = self.is_installed(pin).await;
            models.push(json!({"id":pin.id,"name":pin.name,"size":pin.size,
                "installed":installed,
                "path":installed.then(|| self.directory_for(&pin.id).join(format!("{}.onnx", pin.id))),
                "directory":self.directory_for(&pin.id)}));
        }
        Ok(json!({"models":models}))
    }

    pub async fn download(&self, id: &str, emit: &(impl Fn(Value) + Sync)) -> Result<()> {
        let pin = manifest(id)?;
        let mut completed = 0;
        for file in &pin.files {
            download_file(self.directory_for(id), &file.url, &file.file, file.size, &file.sha256, &|event| {
                let status = if event["status"] == "ready" { "checking" } else { event["status"].as_str().unwrap_or("checking") };
                emit(json!({"type":"progress", "status":status,
                    "downloaded":completed + event["downloaded"].as_u64().unwrap_or(0), "total":pin.size}));
            }).await?;
            completed += file.size;
        }
        emit(json!({"type":"progress","status":"ready","downloaded":pin.size,"total":pin.size}));
        Ok(())
    }
}

pub struct Ollaya;

impl DecisionModel for Ollaya {
    fn evaluate<'a>(&'a self, request: &'a DecisionRequest) -> DecisionFuture<'a> {
        Box::pin(async move {
            request.validate()?;
            let pin = manifest(&request.model)?;
            let questions =
                ollaya_decision::parse_questions(&serde_json::to_value(&request.questions)?)?;
            let directory = ModelStore::configured()?
                .installed_path(&request.model)
                .await?;
            let state = request.state.clone();
            // A dedicated OS thread keeps stdin/signals responsive during native loading and inference.
            // Unlike Tokio's blocking pool it does not prevent process exit after cancellation.
            let (tx, rx) = tokio::sync::oneshot::channel();
            std::thread::Builder::new()
                .name("ollaya-decision".into())
                .spawn(move || {
                    let _ = tx.send(infer(pin, directory, state, questions));
                })?;
            let response = rx
                .await
                .context("The local decision worker stopped unexpectedly.")??;
            response.validate_for(request)?;
            Ok(response)
        })
    }
}

fn infer(
    pin: &Manifest,
    directory: PathBuf,
    state: Value,
    questions: ollaya_decision::Questions,
) -> Result<DecisionResponse> {
    let files = ModelFiles {
        graph: directory.join(format!("{}.onnx", pin.id)),
        tokenizer: directory.join(format!("{}.tokenizer.json", pin.id)),
        decision: directory.join(format!("{}.json", pin.id)),
        calibration: Some(directory.join(format!("{}.calibration.json", pin.id))),
        arch: None,
        weights: None,
    };
    let model = OnnxModel::load_files(&files, Device::Cpu, Some(4))
        .context("Could not load the local decision model.")?;
    let encoding = model.encode(&state, &questions)?;
    if encoding.questions.iter().any(|row| row.state_truncated) {
        bail!("The state exceeds this decision model's context. Supply a shorter state.");
    }
    let mut answers = BTreeMap::new();
    let mut input_tokens = 0;
    // One row at a time bounds native attention memory even for 64 questions.
    for ((id, question), row) in questions.into_iter().zip(encoding.questions) {
        let single = ollaya_decision::Questions::from_iter([(id.clone(), question)]);
        let output = model.run_encoded(
            &Encoding {
                questions: vec![row],
                state_tokens: encoding.state_tokens,
            },
            &single,
        )?;
        let raw = output
            .questions
            .first()
            .context("The local model omitted an answer.")?;
        let question = &single[&id];
        let answer = ollaya_decision::Answer::new(
            question,
            &model.calibration,
            &raw.logits,
            raw.act_logits.as_deref(),
            output.state_tokens,
        );
        answers.insert(id, serde_json::from_value(answer.to_typesafe(question))?);
        input_tokens += output.input_tokens as u64;
    }
    Ok(DecisionResponse {
        model: format!("{}@{}", pin.id, pin.revision),
        answers,
        usage: Some(Usage {
            input_tokens,
            output_tokens: 0,
        }),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};

    #[tokio::test]
    async fn installation_requires_present_artifacts_without_hash_or_metadata_checks() {
        let data = tempfile::tempdir().unwrap();
        let store = ModelStore::new(data.path());
        let mut pin = Manifest {
            id: "fixture".into(),
            name: "Fixture".into(),
            size: 8,
            revision: "revision".into(),
            files: Vec::new(),
        };
        std::fs::create_dir_all(data.path()).unwrap();
        for name in ["model.onnx", "model.safetensors"] {
            pin.files.push(ModelFile {
                file: name.into(),
                url: String::new(),
                size: 4,
                sha256: format!("{:x}", Sha256::digest(b"good")),
            });
        }
        let graph = data.path().join("model.onnx");
        let weights = data.path().join("model.safetensors");
        std::fs::write(&graph, b"good").unwrap();
        assert!(!store.is_installed(&pin).await);
        std::fs::write(&weights, b"good").unwrap();
        assert!(store.is_installed(&pin).await);
        for path in [&graph, &weights] {
            std::fs::write(path, b"evil").unwrap();
            assert!(store.is_installed(&pin).await);
            std::fs::remove_file(path).unwrap();
            assert!(!store.is_installed(&pin).await);
            std::fs::write(path, b"good").unwrap();
        }
    }
}
