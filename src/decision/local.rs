//! Local typed inference runs only in the private decision harness. Installation is explicit.
use super::{DecisionFuture, DecisionModel, DecisionRequest, DecisionResponse, Usage};
use crate::local::models::download_file;
use anyhow::{Context, Result, bail};
use ollaya_runner::{Device, ModelFiles};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{collections::BTreeMap, path::PathBuf};

mod bosun;

#[derive(Clone, Copy, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
enum Engine {
    #[default]
    Ollaya,
    Bosun,
}

#[derive(Deserialize)]
pub struct Manifest {
    pub id: String,
    pub name: String,
    pub size: u64,
    revision: String,
    #[serde(default)]
    engine: Engine,
    #[serde(default)]
    entry_file: Option<String>,
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
#[derive(Clone)]
pub struct ModelStore {
    directory: PathBuf,
    model_directories: BTreeMap<String, PathBuf>,
}

/// Private-pipe model paths supplied by the owning application, never discovered by inference.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ModelStoreConfiguration {
    pub directory: PathBuf,
    #[serde(default)]
    pub model_directories: BTreeMap<String, PathBuf>,
}

impl ModelStore {
    pub fn configuration(&self) -> ModelStoreConfiguration {
        ModelStoreConfiguration {
            directory: self.directory.clone(),
            model_directories: self.model_directories.clone(),
        }
    }

    pub fn from_configuration(config: ModelStoreConfiguration) -> Result<Self> {
        if !config.directory.is_absolute()
            || config
                .model_directories
                .iter()
                .any(|(id, path)| id.trim().is_empty() || !path.is_absolute())
        {
            bail!("Local decision models require absolute host-owned model directories.");
        }
        Ok(Self::new(config.directory).with_model_directories(config.model_directories))
    }

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
                "{} ({id}) is not installed. Download it through the owning app's Models → + → Provider → Ollaya.",
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
                "path":installed.then(|| self.directory_for(&pin.id).join(pin.entry_file.clone().unwrap_or_else(|| format!("{}.onnx", pin.id)))),
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

pub struct Ollaya {
    store: ModelStore,
}

impl Ollaya {
    pub fn new(store: ModelStore) -> Self {
        Self { store }
    }
}

impl DecisionModel for Ollaya {
    fn evaluate<'a>(&'a self, request: &'a DecisionRequest) -> DecisionFuture<'a> {
        Box::pin(async move {
            request.validate()?;
            let pin = manifest(&request.model)?;
            if pin.engine == Engine::Bosun {
                let directory = self.store.installed_path(&request.model).await?;
                let response = bosun::evaluate(pin, directory, request.clone()).await?;
                response.validate_for(request)?;
                return Ok(response);
            }
            let questions =
                ollaya_decision::parse_questions(&serde_json::to_value(&request.questions)?)?;
            let directory = self.store.installed_path(&request.model).await?;
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
    let calibration: ollaya_decision::CalibrationFile = serde_json::from_slice(&std::fs::read(
        files
            .calibration
            .as_ref()
            .context("Missing calibration path.")?,
    )?)
    .context("Invalid local decision calibration.")?;
    let calibration = ollaya_decision::Calibration::from_file(&calibration);
    let model = ollaya_runner::engine::load(&files, Device::Cpu, Some(4))
        .context("Could not load the local decision model.")?;
    let mut answers = BTreeMap::new();
    let mut input_tokens = 0;
    // One row at a time bounds native attention memory even for 64 questions.
    for (id, question) in questions {
        let single = ollaya_decision::Questions::from_iter([(id.clone(), question)]);
        let output = model.run(&state, &single)?;
        let question = &single[&id];
        answers.insert(id, render_output(question, &calibration, &output)?);
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

fn render_output(
    question: &ollaya_decision::Question,
    calibration: &ollaya_decision::Calibration,
    output: &ollaya_runner::Output,
) -> Result<super::Answer> {
    if output.state_truncated {
        bail!("The state exceeds this decision model's context. Supply a shorter state.");
    }
    if output.questions.len() != 1 {
        bail!("The local model returned an invalid answer count.");
    }
    let raw = &output.questions[0];
    let count = match &question.criteria {
        ollaya_decision::Criteria::Choice(options) => options.len(),
        ollaya_decision::Criteria::Score(levels) => levels.len(),
        ollaya_decision::Criteria::Noul { .. } => 2,
    };
    if raw.logits.len() != count
        || raw.logits.iter().any(|x| !x.is_finite())
        || raw
            .act_logits
            .as_ref()
            .is_some_and(|logits| logits.len() != 2 || logits.iter().any(|x| !x.is_finite()))
    {
        bail!("The local model returned invalid option scores.");
    }
    let answer = ollaya_decision::Answer::new(
        question,
        calibration,
        &raw.logits,
        raw.act_logits.as_deref(),
        output.state_tokens,
    );
    Ok(serde_json::from_value(answer.to_typesafe(question))?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};

    #[test]
    fn raw_scores_are_calibrated_and_incomplete_state_is_rejected() {
        let question = ollaya_decision::Question::parse(
            "priority",
            &json!({
                "type":"score", "instructions":"How urgent?", "criteria":["low", "medium", "high"]
            }),
        )
        .unwrap();
        let calibration = ollaya_decision::Calibration::from_file(
            &serde_json::from_value(json!({
                "temperature":[2.0, 2.0, 2.0]
            }))
            .unwrap(),
        );
        let mut output = ollaya_runner::Output {
            questions: vec![ollaya_runner::QuestionOutput {
                logits: vec![0.1_f32.ln() * 2.0, 0.1_f32.ln() * 2.0, 0.8_f32.ln() * 2.0],
                act_logits: None,
            }],
            input_tokens: 20,
            state_tokens: 8,
            state_truncated: false,
        };
        let answer =
            serde_json::to_value(render_output(&question, &calibration, &output).unwrap()).unwrap();
        assert_eq!(answer["probabilities"], json!({"0":0.1,"1":0.1,"2":0.8}));
        assert_eq!(answer["score"], 1.7);
        assert_eq!(answer["confidence"], 0.7);
        assert_eq!(answer["legend"], json!({"0":"low","1":"medium","2":"high"}));
        output.state_truncated = true;
        assert!(
            render_output(&question, &calibration, &output)
                .unwrap_err()
                .to_string()
                .contains("context")
        );
        output.state_truncated = false;
        output.questions[0].logits[0] = f32::NAN;
        assert!(render_output(&question, &calibration, &output).is_err());
        output.questions[0].logits = vec![0.0, 1.0];
        assert!(render_output(&question, &calibration, &output).is_err());
    }

    #[tokio::test]
    async fn explicit_store_resolves_only_its_model_override() {
        let data = tempfile::tempdir().unwrap();
        let alternate = data.path().join("alternate");
        std::fs::create_dir(&alternate).unwrap();
        let pin = manifest("kev-4b").unwrap();
        for file in &pin.files {
            std::fs::write(alternate.join(&file.file), b"invalid model contents").unwrap();
        }
        let default = ModelStore::new(data.path().join("default"));
        assert!(default.installed_path("kev-4b").await.is_err());
        let config = default
            .with_model_directories(BTreeMap::from([("kev-4b".into(), alternate.clone())]))
            .configuration();
        let store = ModelStore::from_configuration(config).unwrap();
        assert_eq!(store.installed_path("kev-4b").await.unwrap(), alternate);
        assert!(store.installed_path("laya-en").await.is_err());
        assert!(!data.path().join("default").exists());
    }

    #[tokio::test]
    async fn installation_requires_present_artifacts_without_hash_or_metadata_checks() {
        let data = tempfile::tempdir().unwrap();
        let store = ModelStore::new(data.path());
        let mut pin = Manifest {
            id: "fixture".into(),
            name: "Fixture".into(),
            size: 8,
            revision: "revision".into(),
            engine: Engine::Ollaya,
            entry_file: None,
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
