//! Ollaya inference runs only in the private decision harness. Installation is explicit.
use super::{DecisionFuture, DecisionModel, DecisionRequest, DecisionResponse, Usage};
use crate::local::models::{download_file, verified};
use anyhow::{Context, Result, bail};
use ollaya_runner::{Device, Encoding, OnnxModel};
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

/// A host-selected cache, separate from the conversational model cache.
pub struct ModelStore {
    directory: PathBuf,
}

impl ModelStore {
    pub fn new(directory: impl Into<PathBuf>) -> Self {
        Self {
            directory: directory.into(),
        }
    }

    fn path(&self, pin: &Manifest) -> PathBuf {
        self.directory
            .join("DecisionModels")
            .join(&pin.id)
            .join(&pin.revision)
    }

    async fn is_installed(&self, pin: &Manifest) -> bool {
        for file in &pin.files {
            if !verified(&self.path(pin).join(&file.file), file.size, &file.sha256).await {
                return false;
            }
        }
        true
    }

    pub async fn installed_path(&self, id: &str) -> Result<PathBuf> {
        let pin = manifest(id)?;
        if !self.is_installed(pin).await {
            bail!(
                "{} is not installed or failed verification. Download it in Models → + → Provider → Ollaya, or run `fritz decision-models install {id}`.",
                pin.name
            );
        }
        Ok(self.path(pin))
    }

    pub async fn inventory(&self, id: Option<&str>) -> Result<Value> {
        let pins = match id {
            Some(id) => vec![manifest(id)?],
            None => catalog().iter().collect(),
        };
        let mut models = Vec::new();
        for pin in pins {
            models.push(json!({"id":pin.id,"name":pin.name,"size":pin.size,
                "installed":self.is_installed(pin).await}));
        }
        Ok(json!({"models":models}))
    }

    pub async fn download(&self, id: &str, emit: &(impl Fn(Value) + Sync)) -> Result<()> {
        let pin = manifest(id)?;
        let mut completed = 0;
        for file in &pin.files {
            download_file(&self.path(pin), &file.url, &file.file, file.size, &file.sha256, &|event| {
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
            let directory = ModelStore::new(crate::config::data_dir())
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
    let model = OnnxModel::load(&directory, Device::Cpu, Some(4))
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
    async fn installation_requires_every_artifact_to_pass_integrity_checks() {
        let data = tempfile::tempdir().unwrap();
        let store = ModelStore::new(data.path());
        let mut pin = Manifest {
            id: "fixture".into(),
            name: "Fixture".into(),
            size: 8,
            revision: "revision".into(),
            files: Vec::new(),
        };
        std::fs::create_dir_all(store.path(&pin)).unwrap();
        for name in ["model.onnx", "model.safetensors"] {
            pin.files.push(ModelFile {
                file: name.into(),
                url: String::new(),
                size: 4,
                sha256: format!("{:x}", Sha256::digest(b"good")),
            });
        }
        let graph = store.path(&pin).join("model.onnx");
        let weights = store.path(&pin).join("model.safetensors");
        std::fs::write(&graph, b"good").unwrap();
        assert!(!store.is_installed(&pin).await);
        std::fs::write(&weights, b"good").unwrap();
        assert!(store.is_installed(&pin).await);
        for path in [&graph, &weights] {
            std::fs::write(path, b"evil").unwrap();
            assert!(!store.is_installed(&pin).await);
            std::fs::write(path, b"good").unwrap();
        }
    }
}
