//! Rig integration for hosts with existing completion models and policy hooks.
//! Uses Rig's typed tool dispatch, per-turn active-tool validation and native
//! multimodal history. No application tools or provider credentials live here.

use futures_util::StreamExt;
use rig_agent::{
    agent::{AgentRunner, CompletionCall, MultiTurnStreamItem, PromptResponse, StreamingError},
    completion::PromptError,
};
use rig_core::completion::CompletionError;
use tokio::sync::mpsc::UnboundedReceiver;

/// A host receives completion accounting before the next model/tool step.
/// Returning an error stops the stream, dropping pending work.
pub async fn run(
    runner: AgentRunner,
    mut completion: impl FnMut(&CompletionCall) -> Result<(), PromptError>,
) -> Result<PromptResponse, PromptError> {
    let mut stream = runner.stream().await;
    while let Some(item) = stream.next().await {
        match item {
            Ok(MultiTurnStreamItem::CompletionCall(call)) => completion(&call)?,
            Ok(MultiTurnStreamItem::FinalResponse(response)) => return Ok(response),
            Err(StreamingError::Completion(error)) => {
                return Err(PromptError::CompletionError(error));
            }
            Err(StreamingError::Prompt(error)) => return Err(*error),
            _ => {}
        }
    }
    Err(PromptError::CompletionError(
        CompletionError::ResponseError("The model stream ended without a final response.".into()),
    ))
}

/// Drive a run while forwarding host-defined progress to its transport.
/// A failed transport drops the run immediately. A closed progress channel
/// does not spin or cancel the model. Hosts may flush final policy events after
/// this returns using the same receiver.
pub async fn run_with_progress<E, X>(
    runner: AgentRunner,
    completion: impl FnMut(&CompletionCall) -> Result<(), PromptError>,
    events: &mut UnboundedReceiver<E>,
    mut emit: impl FnMut(E) -> Result<(), X>,
) -> Result<Result<PromptResponse, PromptError>, X> {
    let request = run(runner, completion);
    tokio::pin!(request);
    let mut events_open = true;
    let result = loop {
        tokio::select! {
            result = &mut request => break result,
            event = events.recv(), if events_open => match event {
                Some(event) => emit(event)?,
                None => events_open = false,
            }
        }
    };
    while let Ok(event) = events.try_recv() {
        emit(event)?;
    }
    Ok(result)
}
