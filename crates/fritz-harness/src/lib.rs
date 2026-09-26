//! Application-independent execution. Hosts own tools, prompts, storage and IO.
//! No tools are installed implicitly. Dropping a run drops its in-flight work;
//! host implementations must propagate cancellation to work they spawn.

use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::HashSet, future::Future, time::Duration};

#[cfg(feature = "rig")]
pub mod rig;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ToolDefinition {
    pub name: String,
    pub description: String,
    pub parameters: Value,
}

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
    pub has_text: bool,
}

/// Keeps provider-native history, including opaque reasoning/signatures.
pub trait Model {
    fn turn(&mut self, tools: &[ToolDefinition]) -> impl Future<Output = Result<Turn>>;
    fn results(&mut self, results: Vec<(ToolCall, ToolResult)>) -> Result<()>;
}

/// The host may change the advertised tool set between model turns.
/// The harness validates the entire returned batch against that turn's set
/// before executing anything. Tool-specific policy remains in `execute`.
pub trait Host {
    fn tools(&self) -> Result<Vec<ToolDefinition>>;
    fn execute(&self, call: &ToolCall) -> impl Future<Output = Result<ToolResult>>;
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
        let mut tool_count = 0usize;
        for turn_index in 0..limits.model_turns {
            let definitions = host.tools()?;
            let mut names = HashSet::new();
            for definition in &definitions {
                if !definition.parameters.is_object() {
                    bail!("Tool parameters must be a JSON schema object.");
                }
                if definition.name.is_empty() || !names.insert(definition.name.as_str()) {
                    bail!("Tool names must be nonempty and unique.");
                }
            }
            let turn = model.turn(&definitions).await?;
            if turn.calls.is_empty() {
                if !turn.has_text {
                    bail!("The model returned no text or tool calls.");
                }
                return Ok(());
            }
            if turn.calls.len() > limits.tool_calls.saturating_sub(tool_count) {
                bail!(
                    "The run reached its {}-tool limit. Review the activity and send a follow-up to continue.",
                    limits.tool_calls
                );
            }
            if turn_index + 1 == limits.model_turns {
                bail!(
                    "The run reached its model-turn limit. Pending tool calls were not executed. Review the activity and send a follow-up to continue."
                );
            }
            let mut ids = HashSet::new();
            for call in &turn.calls {
                if !names.contains(call.name.as_str()) {
                    bail!(
                        "The model requested an unavailable tool: {}. No tools in this batch were executed.",
                        call.name
                    );
                }
                if call.id.is_empty() || !ids.insert(call.id.as_str()) {
                    bail!("Tool call IDs must be nonempty and unique within a turn.");
                }
            }
            let mut results = Vec::with_capacity(turn.calls.len());
            for call in turn.calls {
                tool_count += 1;
                let result = host.execute(&call).await?;
                results.push((call, result));
            }
            model.results(results)?;
        }
        unreachable!()
    };
    match tokio::time::timeout(limits.deadline, work).await {
        Ok(result) => result,
        Err(_) => bail!(
            "The run reached its deadline. Review the activity and send a follow-up to continue."
        ),
    }
}
