#![cfg(feature = "rig")]

use fritz_harness::rig::{run, run_with_progress};
use futures_util::stream;
use rig_agent::AgentBuilder;
use rig_core::{
    completion::{CompletionError, CompletionModel, CompletionRequest, CompletionResponse, Usage},
    streaming::{RawStreamingChoice, StreamFinal, StreamingCompletionResponse},
};
use std::{
    future::pending,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use tokio::sync::mpsc;

#[derive(Clone)]
struct Model {
    progress: Option<mpsc::UnboundedSender<()>>,
    dropped: Arc<AtomicBool>,
}

struct Active(Arc<AtomicBool>);
impl Drop for Active {
    fn drop(&mut self) {
        self.0.store(true, Ordering::SeqCst);
    }
}

impl CompletionModel for Model {
    async fn completion(
        &self,
        _: CompletionRequest,
    ) -> Result<CompletionResponse, CompletionError> {
        panic!("streaming harness must use streaming completion")
    }
    async fn stream(
        &self,
        _: CompletionRequest,
    ) -> Result<StreamingCompletionResponse, CompletionError> {
        let _active = Active(self.dropped.clone());
        if let Some(progress) = &self.progress {
            progress.send(()).unwrap();
            return pending().await;
        }
        Ok(StreamingCompletionResponse::stream(
            "fixture",
            Box::pin(stream::iter([
                Ok(RawStreamingChoice::Message("Complete".into())),
                Ok(RawStreamingChoice::FinalResponse(StreamFinal::new(
                    "fixture",
                    Usage::new(),
                ))),
            ])),
        ))
    }
}

#[tokio::test]
async fn closed_progress_channel_keeps_completion_and_accounting() {
    let agent = AgentBuilder::new(Model {
        progress: None,
        dropped: Arc::default(),
    })
    .build();
    let (sender, mut receiver) = mpsc::unbounded_channel::<()>();
    drop(sender);
    let mut completions = 0;
    let response = tokio::time::timeout(
        Duration::from_secs(1),
        run_with_progress(
            agent.runner("Answer"),
            |_| {
                completions += 1;
                Ok(())
            },
            &mut receiver,
            |_| -> Result<(), ()> { panic!("closed channel emitted an event") },
        ),
    )
    .await
    .unwrap()
    .unwrap()
    .unwrap();
    assert_eq!(response.output, "Complete");
    assert_eq!(completions, 1);

    let error = run(agent.runner("Answer"), |_| {
        Err(rig_agent::completion::PromptError::CompletionError(
            CompletionError::ResponseError("host budget exhausted".into()),
        ))
    })
    .await
    .unwrap_err();
    assert!(error.to_string().contains("host budget exhausted"));
}

#[tokio::test]
async fn failed_progress_transport_drops_pending_model_io() {
    let (sender, mut receiver) = mpsc::unbounded_channel();
    let dropped = Arc::new(AtomicBool::new(false));
    let agent = AgentBuilder::new(Model {
        progress: Some(sender),
        dropped: dropped.clone(),
    })
    .build();
    let result = tokio::time::timeout(
        Duration::from_secs(1),
        run_with_progress(
            agent.runner("Wait"),
            |_| Ok(()),
            &mut receiver,
            |_| Err("transport closed"),
        ),
    )
    .await
    .unwrap();
    assert!(matches!(result, Err("transport closed")));
    assert!(dropped.load(Ordering::SeqCst));
}
