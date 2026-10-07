//! Fritz's built-in provider. Pinned weights are installed explicitly and used offline.
pub mod inference;
pub mod models;
pub mod ollama;

use crate::{harness::Call, provider::ChatRequest};
use anyhow::{Context, Result, bail};
use mistralrs::{
    Function, ReasoningEffort, RequestBuilder, Response, TextMessageRole, Tool, ToolCallResponse,
    ToolChoice, ToolType,
};
use serde_json::{Value, json};
use std::collections::HashMap;
use tokio::sync::Mutex;

// The API retains explicitly started models independently of chat harnesses.
static API_ENGINES: Mutex<Option<HashMap<String, inference::Engine>>> = Mutex::const_new(None);

pub(crate) async fn start_model_in(model_id: &str, store: &models::ModelStore) -> Result<()> {
    let mut engines = API_ENGINES.lock().await;
    let engines = engines.get_or_insert_with(HashMap::new);
    if !engines.contains_key(model_id) {
        let engine = inference::Engine::installed_in(store, model_id).await?;
        engine.model().await?;
        engines.insert(model_id.to_owned(), engine);
    }
    Ok(())
}

pub(crate) async fn model_is_started(model_id: &str) -> bool {
    API_ENGINES
        .lock()
        .await
        .as_ref()
        .is_some_and(|engines| engines.contains_key(model_id))
}

pub(crate) async fn stop_model(model_id: &str) {
    if let Some(engine) = API_ENGINES
        .lock()
        .await
        .as_mut()
        .and_then(|engines| engines.remove(model_id))
    {
        engine.unload().await;
    }
}

pub(crate) async fn stop_other_models(model_id: &str) {
    let mut active = API_ENGINES.lock().await;
    if let Some(engines) = active.as_mut() {
        let others: Vec<_> = engines
            .keys()
            .filter(|id| *id != model_id)
            .cloned()
            .collect();
        for id in others {
            if let Some(engine) = engines.remove(&id) {
                engine.unload().await;
            }
        }
    }
}

pub async fn shutdown() {
    if let Some(engines) = API_ENGINES.lock().await.take() {
        for (_, engine) in engines {
            engine.unload().await;
        }
    }
}

pub(crate) struct Session {
    engine: inference::Engine,
    messages: RequestBuilder,
    pending: Vec<ToolCallResponse>,
    pending_text: String,
}

impl Session {
    pub(crate) async fn new(request: &ChatRequest, system: &str) -> Result<Self> {
        let engine = inference::Engine::installed(&request.model).await?;
        let mut messages = RequestBuilder::new().add_message(TextMessageRole::System, system);
        for message in &request.messages {
            let role = match message.role.as_str() {
                "user" => TextMessageRole::User,
                "assistant" => TextMessageRole::Assistant,
                _ => bail!("Invalid role in Fritz conversation."),
            };
            messages = messages.add_message(role, &message.content);
        }
        Ok(Self {
            engine,
            messages,
            pending: Vec::new(),
            pending_text: String::new(),
        })
    }

    pub(crate) async fn turn(
        &mut self,
        definitions: &[fritz_harness::ToolDefinition],
        emit: &(impl Fn(Value) + Sync),
    ) -> Result<Vec<Call>> {
        let mut request = self.messages.clone().set_sampler_max_len(2048);
        if models::manifest(self.engine.model_id())?.disable_thinking {
            request = request.with_reasoning_effort(ReasoningEffort::Off);
        }
        if !definitions.is_empty() {
            let functions = definitions
                .iter()
                .map(|definition| {
                    Ok(Tool {
                        tp: ToolType::Function,
                        function: Function {
                            name: definition.name.clone(),
                            description: Some(definition.description.clone()),
                            parameters: Some(serde_json::from_value(
                                definition.parameters.clone(),
                            )?),
                            strict: Some(false),
                        },
                    })
                })
                .collect::<Result<Vec<_>>>()?;
            request = request
                .set_tools(functions)
                .set_tool_choice(ToolChoice::Auto);
        }
        let model = self.engine.model().await?;
        let mut stream = model.stream_chat_request(request).await?;
        let mut text = String::new();
        let mut calls = Vec::<ToolCallResponse>::new();
        let mut finish_reason = None;
        while let Some(response) = stream.next().await {
            match response {
                Response::Chunk(chunk) => {
                    if let Some(usage) = chunk.usage {
                        emit(
                            json!({"type":"usage","usage":{"input_tokens":usage.prompt_tokens,"output_tokens":usage.completion_tokens,"total_tokens":usage.total_tokens}}),
                        );
                    }
                    for choice in chunk.choices {
                        if choice.index != 0 {
                            bail!("The local model returned multiple choices.");
                        }
                        if let Some(delta) = choice.delta.content {
                            text.push_str(&delta);
                            emit(json!({"type":"delta","text":delta}));
                        }
                        if let Some(tool_calls) = choice.delta.tool_calls {
                            for call in tool_calls {
                                if !calls.iter().any(|previous| previous.id == call.id) {
                                    calls.push(call);
                                }
                            }
                        }
                        if let Some(reason) = choice.finish_reason {
                            if !matches!(reason.as_str(), "stop" | "tool_calls") {
                                bail!(
                                    "The local model stopped before completing the turn ({reason})."
                                );
                            }
                            finish_reason = Some(reason);
                        }
                    }
                }
                Response::InternalError(error) | Response::ValidationError(error) => {
                    return Err(anyhow::anyhow!(error.to_string()));
                }
                Response::ModelError(error, _) => bail!("Local model failed: {error}"),
                _ => {}
            }
        }
        if finish_reason.is_none() {
            bail!("The local model did not finish a complete turn. No tools were executed.");
        }
        if finish_reason.as_deref() == Some("tool_calls") && calls.is_empty() {
            bail!("The local model returned an incomplete tool call. No tools were executed.");
        }
        if calls.is_empty() {
            self.messages = self
                .messages
                .clone()
                .add_message(TextMessageRole::Assistant, text);
            return Ok(Vec::new());
        }
        self.pending_text = text;
        self.pending = calls.clone();
        Ok(calls
            .into_iter()
            .map(|call| Call {
                id: call.id,
                name: call.function.name,
                arguments: call.function.arguments,
            })
            .collect())
    }

    pub(crate) fn results(&mut self, results: &[(Call, fritz_harness::ToolResult)]) -> Result<()> {
        if results.iter().any(|(_, result)| !result.images.is_empty()) {
            bail!("The local text model does not support image tool results.");
        }
        self.messages = self.messages.clone().add_message_with_tool_call(
            TextMessageRole::Assistant,
            std::mem::take(&mut self.pending_text),
            std::mem::take(&mut self.pending),
        );
        for (call, result) in results {
            self.messages = self
                .messages
                .clone()
                .add_tool_message(&result.value, &call.id);
        }
        Ok(())
    }
}

pub async fn generate(
    model_id: &str,
    messages: Vec<(String, String)>,
    json_format: bool,
    context_size: usize,
    output_limit: usize,
    output: tokio::sync::mpsc::UnboundedSender<String>,
) -> Result<(u64, u64, bool)> {
    generate_in(
        &models::ModelStore::configured()?,
        model_id,
        messages,
        json_format,
        context_size,
        output_limit,
        output,
    )
    .await
}

/// Generate through the local API using the host's explicit model store.
#[allow(clippy::too_many_arguments)]
pub async fn generate_in(
    store: &models::ModelStore,
    model_id: &str,
    messages: Vec<(String, String)>,
    json_format: bool,
    context_size: usize,
    output_limit: usize,
    output: tokio::sync::mpsc::UnboundedSender<String>,
) -> Result<(u64, u64, bool)> {
    let mut active = API_ENGINES.lock().await;
    let engines = active.get_or_insert_with(HashMap::new);
    if engines
        .get(model_id)
        .is_none_or(|engine| engine.context_size() != context_size)
    {
        if let Some(previous) = engines.remove(model_id) {
            previous.unload().await;
        }
        let engine =
            inference::Engine::installed_in_with_context(store, model_id, context_size).await?;
        engine.model().await?;
        engines.insert(model_id.to_owned(), engine);
    }
    generate_with_engine(
        &engines[model_id],
        messages,
        json_format,
        output_limit,
        output,
    )
    .await
}

/// Generate with a host-created engine; no Fritz default store or Keychain is read.
pub async fn generate_with_engine(
    engine: &inference::Engine,
    messages: Vec<(String, String)>,
    json_format: bool,
    output_limit: usize,
    output: tokio::sync::mpsc::UnboundedSender<String>,
) -> Result<(u64, u64, bool)> {
    use mistralrs::Constraint;
    let model_id = engine.model_id();
    let mut request = RequestBuilder::new().set_sampler_max_len(output_limit);
    if models::manifest(model_id)?.disable_thinking {
        request = request.with_reasoning_effort(ReasoningEffort::Off);
    }
    for (role, content) in messages {
        request = request.add_message(
            match role.as_str() {
                "system" => TextMessageRole::System,
                "user" => TextMessageRole::User,
                "assistant" => TextMessageRole::Assistant,
                _ => bail!("Invalid local model message role."),
            },
            content,
        );
    }
    if json_format {
        request = request.set_constraint(Constraint::JsonSchema(json!({})));
    }
    let mut stream = engine.model().await?.stream_chat_request(request).await?;
    let mut usage = None;
    let mut truncated = false;
    while let Some(response) = stream.next().await {
        match response {
            Response::Chunk(chunk) => {
                if let Some(found) = chunk.usage {
                    usage = Some((found.prompt_tokens as u64, found.completion_tokens as u64));
                }
                for choice in chunk.choices {
                    if let Some(text) = choice.delta.content {
                        output.send(text).context("Generation cancelled")?;
                    }
                    truncated |= choice.finish_reason.as_deref() == Some("length");
                }
            }
            Response::InternalError(error) | Response::ValidationError(error) => {
                return Err(anyhow::anyhow!(error.to_string()));
            }
            Response::ModelError(error, _) => bail!("Local model failed: {error}"),
            _ => {}
        }
    }
    let (input, output_count) = usage.context("The local model returned no usage")?;
    Ok((input, output_count, truncated))
}
