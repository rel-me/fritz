#![cfg(feature = "rig")]

use fritz_harness::rig::{run, run_with_progress};
use futures_util::stream;
use rig_agent::AgentBuilder;
use rig_core::{
    completion::CompletionRequest,
    driver::{Exchange, Model as CompletionModel, Opened, Opening, Transport},
    error::ProviderError,
    operation::Finish,
    test_utils::{MockFrame, MockScript, MockStreamEvent},
    wire::Mode,
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

impl Model {
    fn completion_model(self) -> CompletionModel<MockScript, Self> {
        CompletionModel::new(MockScript::new("fixture"), self)
    }
}

impl Transport<MockScript> for Model {
    fn send(&self, _: CompletionRequest, exchange: Exchange) -> Opening<MockFrame> {
        assert_eq!(exchange.mode, Mode::Streaming);
        let progress = self.progress.clone();
        let dropped = self.dropped.clone();
        Opening::new(async move {
            let _active = Active(dropped);
            if let Some(progress) = progress {
                progress.send(()).unwrap();
                return pending().await;
            }
            Ok(Opened::new(stream::iter([
                Ok(MockFrame::Event(MockStreamEvent::text("Complete"))),
                Ok(MockFrame::Event(MockStreamEvent::FinalResponse(
                    Finish::default(),
                ))),
            ])))
        })
    }
}

#[tokio::test]
// The host callback's public signature returns Rig's unboxed PromptError.
#[allow(clippy::result_large_err)]
async fn closed_progress_channel_keeps_completion_and_accounting() {
    let agent = AgentBuilder::new(
        Model {
            progress: None,
            dropped: Arc::default(),
        }
        .completion_model(),
    )
    .build();
    let (sender, mut receiver) = mpsc::unbounded_channel::<()>();
    drop(sender);
    let mut completions = 0;
    let response = tokio::time::timeout(
        Duration::from_secs(1),
        run_with_progress(
            agent.prompt("Answer"),
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

    let error = run(agent.prompt("Answer"), |_| {
        Err(rig_agent::completion::PromptError::CompletionError(
            ProviderError::Response("host budget exhausted".into()),
        ))
    })
    .await
    .unwrap_err();
    assert!(error.to_string().contains("host budget exhausted"));
}

#[tokio::test]
// The host callback's public signature returns Rig's unboxed PromptError.
#[allow(clippy::result_large_err)]
async fn failed_progress_transport_drops_pending_model_io() {
    let (sender, mut receiver) = mpsc::unbounded_channel();
    let dropped = Arc::new(AtomicBool::new(false));
    let agent = AgentBuilder::new(
        Model {
            progress: Some(sender),
            dropped: dropped.clone(),
        }
        .completion_model(),
    )
    .build();
    let result = tokio::time::timeout(
        Duration::from_secs(1),
        run_with_progress(
            agent.prompt("Wait"),
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
