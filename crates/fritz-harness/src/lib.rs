//! Rig-driven execution with host-owned prompts, storage and provider IO.
//! No tools are installed implicitly. Dropping a run drops its in-flight work;
//! host implementations must propagate cancellation to work they spawn.

use anyhow::{Context, Result, bail};
use rig_agent::{
    agent::InvalidToolCallAction,
    run::{
        AgentRun, AgentRunStep, ModelTurn, ModelTurnOutcome, PendingToolCall, policy::TurnPolicy,
    },
};
use rig_core::{
    completion::{AssistantMessage, Usage},
    message::{
        AssistantContent, ImageMediaType, Message, MimeType, ToolName, ToolResultContent,
        UserContent,
    },
};
use serde_json::Value;
use std::{
    collections::{HashMap, HashSet},
    future::Future,
    sync::Arc,
    time::Duration,
};

pub use rig_agent::tool as tools;
pub use rig_core::providers::openai::responses_api::ResponsesToolDefinition;
pub use rig_core::{completion::ToolDefinition, message};

#[cfg(feature = "rig")]
pub mod rig;

#[derive(Clone, Debug)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments: String,
}

/// Model-facing output. Provider adapters must preserve images or reject them
/// explicitly; serializing image bytes as prose is not a supported conversion.
#[derive(Clone, Debug)]
pub struct Image {
    pub media_type: String,
    pub base64: String,
}

#[derive(Clone, Debug)]
pub struct ToolResult {
    pub value: Value,
    pub images: Vec<Image>,
    pub failed: bool,
}

impl ToolResult {
    pub fn json(value: Value, failed: bool) -> Self {
        Self {
            value,
            images: Vec::new(),
            failed,
        }
    }
}

pub struct Turn {
    pub calls: Vec<ToolCall>,
    pub text: String,
}

/// Keeps provider-native history, including opaque reasoning/signatures.
pub trait Model {
    /// Initial conversation for Rig's run state. Provider-specific history,
    /// including opaque reasoning, remains in the adapter used by `turn`.
    fn conversation(&self) -> Vec<Message>;
    /// Optional bounded conversation view. Adapters update their native history
    /// first; the run keeps its tool-resolution state and uses this view for policy.
    fn compact_conversation(&mut self) -> Result<Option<Vec<Message>>> {
        Ok(None)
    }
    /// Host policy inspects the current typed conversation before tool selection
    /// or provider IO.
    fn prepare(&mut self, _history: &[Message], _prompt: &Message, _turn: usize) -> Result<()> {
        Ok(())
    }
    fn turn(&mut self, tools: &[ToolDefinition]) -> impl Future<Output = Result<Turn>>;
    fn results(&mut self, results: Vec<(ToolCall, ToolResult)>) -> Result<()>;
}

/// The host may change the advertised tool set between model turns.
/// The harness validates the entire returned batch against that turn's set
/// before executing anything. Tool-specific policy remains in `execute`.
pub trait Host {
    fn tools(&self) -> Result<Vec<ToolDefinition>>;
    fn execute(&self, call: &ToolCall) -> impl Future<Output = Result<ToolResult>>;

    /// By default, an unavailable tool stops the run. A host may return a
    /// model-facing error to allow correction. This callback must not execute
    /// the rejected tool. If any call is unavailable, the whole batch is skipped.
    fn unavailable_tool(&self, call: &ToolCall) -> Result<ToolResult> {
        bail!(
            "The model requested an unavailable tool: {}. No tools in this batch were executed.",
            call.name
        )
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Limits {
    pub model_turns: usize,
    pub tool_calls: usize,
    pub deadline: Duration,
}

/// Run provider-native turns with a host's tools. No background tasks are
/// spawned by the engine, so timeout or caller cancellation drops active IO.
pub async fn run(model: &mut impl Model, host: &impl Host, limits: Limits) -> Result<()> {
    if limits.model_turns == 0 || limits.deadline.is_zero() {
        bail!("Model-turn limit and deadline must be positive.");
    }
    let work = async {
        let mut history = model.conversation();
        let prompt = history
            .pop()
            .context("A conversation must contain a message.")?;
        let mut run = AgentRun::new(prompt)
            .with_history(history)
            .max_turns(limits.model_turns);
        let mut tool_count = 0usize;
        let mut step = run.next_step()?;
        loop {
            step = match step {
                AgentRunStep::CallModel {
                    turn: index,
                    history,
                    prompt,
                } => {
                    let compacted = model.compact_conversation()?;
                    let (history, prompt) = if let Some(mut conversation) = compacted {
                        let prompt = conversation
                            .pop()
                            .context("Compacted conversation is empty.")?;
                        (conversation, prompt)
                    } else {
                        (
                            history.into_iter().map(Arc::unwrap_or_clone).collect(),
                            Arc::unwrap_or_clone(prompt),
                        )
                    };
                    model.prepare(&history, &prompt, index)?;
                    let definitions = host.tools()?;
                    let mut names = std::collections::BTreeSet::new();
                    for definition in &definitions {
                        if !definition.parameters.is_object() {
                            bail!("Tool parameters must be a JSON schema object.");
                        }
                        if definition.name.is_empty() || !names.insert(definition.name.to_string())
                        {
                            bail!("Tool names must be nonempty and unique.");
                        }
                    }
                    let turn = model.turn(&definitions).await?;
                    if turn.calls.is_empty() && turn.text.trim().is_empty() {
                        bail!("The model returned no text or tool calls.");
                    }
                    // Fritz policy reserves a model turn to consume every tool
                    // result, and rejects over-budget batches before side effects.
                    if turn.calls.len() > limits.tool_calls.saturating_sub(tool_count) {
                        bail!(
                            "The run reached its {}-tool limit. Review the activity and send a follow-up to continue.",
                            limits.tool_calls
                        );
                    }
                    if !turn.calls.is_empty() && index == limits.model_turns {
                        bail!(
                            "The run reached its model-turn limit. Pending tool calls were not executed. Review the activity and send a follow-up to continue."
                        );
                    }
                    let mut ids = HashSet::new();
                    let mut content = Vec::new();
                    if !turn.text.is_empty() {
                        content.push(AssistantContent::text(turn.text));
                    }
                    for call in turn.calls {
                        if call.id.is_empty() || !ids.insert(call.id.clone()) {
                            bail!("Tool call IDs must be nonempty and unique within a turn.");
                        }
                        content.push(AssistantContent::tool_call(
                            call.id,
                            ToolName::new(call.name)?,
                            Value::Object(
                                serde_json::from_str(&call.arguments)
                                    .context("Invalid tool arguments; no tools executed.")?,
                            ),
                        ));
                    }
                    let policy = TurnPolicy::new(names, None, None)?;
                    let mut outcome = run.model_response(ModelTurn::new(
                        AssistantMessage::default(),
                        content,
                        Usage::default(),
                        policy,
                        Value::Null,
                    ))?;
                    let mut rejected = HashMap::new();
                    while let ModelTurnOutcome::NeedsResolution(context) = outcome {
                        let call = ToolCall {
                            id: context
                                .tool_call_id
                                .context("Missing rejected tool call ID.")?
                                .to_string(),
                            name: context.tool_name,
                            arguments: context.args.context("Missing rejected tool arguments.")?,
                        };
                        let result = host.unavailable_tool(&call)?;
                        let feedback = result.value.to_string();
                        rejected.insert(call.id, result);
                        // Rig's Skip resolution suppresses the entire batch,
                        // including otherwise valid peers, and preserves receipts.
                        outcome =
                            run.resolve_invalid_tool_call(InvalidToolCallAction::skip(feedback))?;
                    }
                    let next = run.next_step()?;
                    if !rejected.is_empty() {
                        let results = skipped_results(&next, rejected)?;
                        tool_count += results.len();
                        model.results(results)?;
                    }
                    next
                }
                AgentRunStep::CallTools { calls } => {
                    let calls = calls
                        .into_iter()
                        .map(|call| match call {
                            PendingToolCall::Execute(call) => Ok(call),
                            _ => {
                                bail!("Rig returned a nonexecutable tool call; no tools executed.")
                            }
                        })
                        .collect::<Result<Vec<_>>>()?;
                    tool_count += calls.len();
                    let mut results = Vec::with_capacity(calls.len());
                    let mut answers = Vec::with_capacity(calls.len());
                    for pending in calls {
                        let call = host_call(pending.tool_call());
                        let result = host.execute(&call).await?;
                        let mut content = vec![match &result.value {
                            Value::String(text) => ToolResultContent::text(text),
                            value => ToolResultContent::json(value.clone()),
                        }];
                        for image in &result.images {
                            content.push(ToolResultContent::image_base64(
                                image.base64.clone(),
                                Some(
                                    ImageMediaType::from_mime_type(&image.media_type)
                                        .context("Unsupported image media type.")?,
                                ),
                                None,
                            ));
                        }
                        let output = tools::ToolOutput::content(content)?;
                        let answer = if result.failed {
                            tools::ToolResult::failed(
                                tools::ToolExecutionError::other("The tool reported a failure.")
                                    .with_model_output(output),
                            )
                        } else {
                            tools::ToolResult::success(output)
                        };
                        answers.push(pending.answer(answer));
                        results.push((call, result));
                    }
                    model.results(results)?;
                    run.answer_all(answers)?;
                    run.next_step()?
                }
                AgentRunStep::Done(_) => return Ok(()),
            };
        }
    };
    match tokio::time::timeout(limits.deadline, work).await {
        Ok(result) => result,
        Err(_) => bail!(
            "The run reached its deadline. Review the activity and send a follow-up to continue."
        ),
    }
}

fn host_call(call: &message::ToolCall) -> ToolCall {
    ToolCall {
        id: call.id.to_string(),
        name: call.function.name.to_string(),
        arguments: call.function.arguments_json(),
    }
}

// Rig commits a skipped batch before requesting the next model turn. Deliver
// those same receipts to the host's provider-native history before it runs.
fn skipped_results(
    next: &AgentRunStep,
    mut rejected: HashMap<String, ToolResult>,
) -> Result<Vec<(ToolCall, ToolResult)>> {
    let AgentRunStep::CallModel {
        history, prompt, ..
    } = next
    else {
        bail!("Rig did not advance after skipping the tool batch.");
    };
    let (Some(Message::Assistant(turn)), Message::User { content }) =
        (history.last().map(Arc::as_ref), prompt.as_ref())
    else {
        bail!("Rig did not commit the skipped tool receipts.");
    };
    let calls = turn
        .content
        .iter()
        .filter_map(AssistantContent::as_tool_call);
    if calls.clone().count() != content.len() {
        bail!("Rig returned an incomplete skipped tool batch.");
    }
    calls
        .zip(content)
        .map(|(call, receipt)| {
            let UserContent::ToolResult(receipt) = receipt else {
                bail!("Rig returned an invalid skipped tool receipt.");
            };
            if receipt.call != call.id {
                bail!("Rig mismatched a skipped tool receipt.");
            }
            let call = host_call(call);
            let result = match rejected.remove(&call.id) {
                Some(result) => result,
                None => {
                    let feedback = tools::ToolOutput::content(receipt.content.clone())?.render();
                    ToolResult::json(serde_json::json!({"error": feedback}), true)
                }
            };
            Ok((call, result))
        })
        .collect()
}
