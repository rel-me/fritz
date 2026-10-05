//! Explicit, child-scoped ONNX residency. No registry, credentials, history or global cache.
use super::{Engine, LoadedModel, ModelStore, manifest};
use crate::decision::{DecisionFuture, DecisionModel, DecisionRequest, DecisionResponse};
use anyhow::{Context, Result, bail, ensure};
use std::{
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
};

struct Job {
    request: DecisionRequest,
    reply: tokio::sync::oneshot::Sender<Result<DecisionResponse>>,
}

/// A fixed-model session for an owned decision child. Dropping a request future does
/// not cancel native work: the host must terminate/reap its child on cancellation.
/// New requests are rejected while work remains active. Drop disconnects the worker;
/// the private resident harness uses `_exit` after flushing shutdown/cancellation.
pub struct ResidentOllaya {
    model: String,
    resolved_model: String,
    directory: PathBuf,
    jobs: mpsc::SyncSender<Job>,
    busy: Arc<AtomicBool>,
}

impl ResidentOllaya {
    pub async fn open(store: ModelStore, model: &str) -> Result<Self> {
        let pin = manifest(model)?;
        ensure!(
            pin.engine == Engine::Ollaya,
            "This model does not support resident ONNX evaluation; use one-shot evaluation."
        );
        let directory = std::fs::canonicalize(store.installed_path(model).await?)
            .context("Could not resolve the installed decision model directory.")?;
        let (jobs, receiver) = mpsc::sync_channel::<Job>(1);
        let busy = Arc::new(AtomicBool::new(false));
        let worker_busy = Arc::clone(&busy);
        let worker_directory = directory.clone();
        std::thread::Builder::new()
            .name("resident-ollaya-decision".into())
            .spawn(move || {
                let mut loaded: Option<LoadedModel> = None;
                let mut failure: Option<String> = None;
                while let Ok(job) = receiver.recv() {
                    let result: Result<DecisionResponse> = (|| {
                        if let Some(error) = &failure {
                            bail!("{error}");
                        }
                        if loaded.is_none() {
                            loaded = Some(LoadedModel::load(pin, &worker_directory)?);
                        }
                        let questions = ollaya_decision::parse_questions(&serde_json::to_value(
                            &job.request.questions,
                        )?)?;
                        let response = loaded
                            .as_ref()
                            .unwrap()
                            .infer(job.request.state.clone(), questions)?;
                        response.validate_for(&job.request)?;
                        Ok(response)
                    })();
                    // Retain native failures rather than silently reloading or continuing
                    // an engine whose state after an error has not been qualified.
                    if let Err(error) = &result {
                        failure = Some(format!("{error:#}"));
                    }
                    // Native work is complete before admission reopens. A dropped reply
                    // receiver never reopens admission while native inference is running.
                    worker_busy.store(false, Ordering::Release);
                    let _ = job.reply.send(result);
                }
            })?;
        Ok(Self {
            model: model.into(),
            resolved_model: format!("{}@{}", pin.id, pin.revision),
            directory,
            jobs,
            busy,
        })
    }

    pub fn resolved_model(&self) -> &str {
        &self.resolved_model
    }
    pub fn model_directory(&self) -> &std::path::Path {
        &self.directory
    }
}

impl DecisionModel for ResidentOllaya {
    fn evaluate<'a>(&'a self, request: &'a DecisionRequest) -> DecisionFuture<'a> {
        Box::pin(async move {
            request.validate()?;
            ensure!(
                request.model == self.model,
                "Resident decisions cannot change the session model."
            );
            ensure!(
                self.busy
                    .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                    .is_ok(),
                "The resident decision session is busy; requests must be serial."
            );
            let (reply, response) = tokio::sync::oneshot::channel();
            if self
                .jobs
                .try_send(Job {
                    request: request.clone(),
                    reply,
                })
                .is_err()
            {
                self.busy.store(false, Ordering::Release);
                bail!("The resident decision worker is unavailable.");
            }
            response
                .await
                .context("The resident decision worker stopped unexpectedly.")?
        })
    }
}
