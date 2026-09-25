//! Fritz's built-in provider. Model weights are installed explicitly and used offline.
pub mod chat;
pub mod inference;
pub mod models;
pub mod ollama;

use anyhow::{Result, bail};
use serde_json::{Value, json};
use std::time::Duration;
use tokio::sync::Mutex;

// Retain only one loaded model. Requests share weights, never conversation state.
static ENGINE: Mutex<Option<inference::Engine>> = Mutex::const_new(None);

/// Context and output tokens for turns that include project tools.
pub const TOOL_CONTEXT: usize = 32_768;
pub const TOOL_OUTPUT: usize = 8192;

const JSON_GRAMMAR: &str = r#"root ::= ws value ws
value ::= object | array | string | number | "true" | "false" | "null"
object ::= "{" ws (string ws ":" ws value (ws "," ws string ws ":" ws value)*)? ws "}"
array ::= "[" ws (value (ws "," ws value)*)? ws "]"
string ::= "\"" ([^"\\\x00-\x1F] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F]))* "\""
number ::= "-"? ("0" | [1-9] [0-9]*) ("." [0-9]+)? ([eE] [+-]? [0-9]+)?
ws ::= [ \t\n\r]*"#;

pub async fn shutdown() {
    if let Some(engine) = ENGINE.lock().await.take() {
        engine.unload().await;
    }
}

pub async fn generate(
    model_id: &str,
    prompt: String,
    json_format: bool,
    raw: bool,
    context_size: usize,
    output_limit: usize,
    output: tokio::sync::mpsc::UnboundedSender<String>,
) -> Result<(u64, u64, bool)> {
    let mut engine = ENGINE.lock().await;
    if engine
        .as_ref()
        .is_none_or(|engine| engine.model_id != model_id)
    {
        if let Some(previous) = engine.take() {
            previous.unload().await;
        }
        *engine = Some(inference::Engine::installed(model_id).await?);
    }
    let result = engine
        .as_ref()
        .unwrap()
        .generate(
            prompt,
            inference::GenerationOptions {
                grammar: json_format.then_some(JSON_GRAMMAR),
                raw,
                context_size,
                output_limit,
                timeout: Duration::from_secs(300),
            },
            output,
        )
        .await?;
    Ok((result.input_tokens, result.output_tokens, result.truncated))
}

/// Runs one assistant turn with the model's own chat template. `messages` and
/// `tools` are OpenAI-shaped, and so is the returned assistant message. Prose
/// streams as `delta` events; tool calls are returned, never executed here.
pub async fn turn(
    model_id: &str,
    messages: &Value,
    tools: &Value,
    emit: &(impl Fn(Value) + Sync),
) -> Result<Value> {
    let mut engine = ENGINE.lock().await;
    if engine
        .as_ref()
        .is_none_or(|engine| engine.model_id != model_id)
    {
        // Release the previous model before loading another large set of weights.
        *engine = None;
        *engine = Some(inference::Engine::installed(model_id).await?);
    }
    let with_tools = tools.as_array().is_some_and(|tools| !tools.is_empty());
    // Tool schemas and results need more room than conversation-only chat.
    let (context_size, output_limit) = if with_tools {
        (TOOL_CONTEXT, TOOL_OUTPUT)
    } else {
        (8192, 2048)
    };
    let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
    let mut generation = Box::pin(engine.as_ref().unwrap().chat(
        messages.clone(),
        tools.clone(),
        inference::ChatOptions {
            context_size,
            output_limit,
            timeout: Duration::from_secs(300),
        },
        sender,
    ));
    let result = loop {
        tokio::select! {
            Some(text) = receiver.recv() => emit(json!({"type":"delta","text":text})),
            result = &mut generation => break result,
        }
    };
    while let Ok(text) = receiver.try_recv() {
        emit(json!({"type":"delta","text":text}));
    }
    let inference::ChatGeneration { mut message, usage } = result?;
    emit(
        json!({"type":"usage","usage":{"input_tokens":usage.input_tokens,"output_tokens":usage.output_tokens,"total_tokens":usage.input_tokens+usage.output_tokens},"truncated":usage.truncated}),
    );
    if with_tools && usage.truncated {
        bail!("The local model reached its output limit. No tools were executed.");
    }
    if let Some(calls) = message["tool_calls"].as_array_mut() {
        for (index, call) in calls.iter_mut().enumerate() {
            if call["id"].as_str().is_none_or(str::is_empty) {
                call["id"] = json!(format!("fritz-{index}"));
            }
        }
    }
    Ok(message)
}
