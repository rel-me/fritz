use crate::config::{self, Connection, ProviderKind};
use anyhow::{Context, Result, bail};
use futures_util::StreamExt;
use reqwest::{Client, RequestBuilder};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{collections::HashMap, sync::OnceLock, time::Duration};

pub(crate) const SYSTEM: &str = "You are Fritz, a personal assistant in a native macOS app. Help the user answer questions, think through everyday tasks, organize ideas, and draft text. Be clear and accurate. You have no access to personal data beyond what the user shares in this conversation. No tools are available for this request. Do not claim to inspect or change files, run local processes, or access other apps or services.";

#[derive(Clone, Deserialize, Serialize)]
pub struct Message {
    pub role: String,
    pub content: String,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatRequest {
    pub connection_id: String,
    pub model: String,
    pub messages: Vec<Message>,
    #[serde(default)]
    pub effort: Option<String>,
    #[serde(default)]
    pub speed: Option<String>,
    #[serde(default)]
    pub project_path: Option<String>,
    #[serde(default = "default_max_turns")]
    pub max_turns: usize,
}

fn default_max_turns() -> usize {
    24
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Model {
    pub id: String,
    pub display_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub created_at: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub supports_tools: Option<bool>,
}

#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
enum OpenAIModelStatus {
    Active,
    Deprecated,
    Retired,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OpenAIModelMetadata {
    display_name: String,
    reasoning_efforts: Vec<String>,
    speeds: Vec<String>,
    status: OpenAIModelStatus,
    #[serde(deserialize_with = "Option::<String>::deserialize")]
    default_reasoning: Option<String>,
    default_speed: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OpenAIModelCatalog {
    schema_version: u32,
    revision: u64,
    models: HashMap<String, OpenAIModelMetadata>,
}

fn parse_openai_catalog(data: &str) -> Result<OpenAIModelCatalog> {
    let value: Value = serde_json::from_str(data)?;
    let catalog: OpenAIModelCatalog = serde_json::from_value(value["reviewed_openai"].clone())?;
    if catalog.schema_version != 1 || catalog.revision == 0 || catalog.models.is_empty() {
        bail!("Unsupported or empty OpenAI model catalog");
    }
    for entry in catalog.models.values() {
        if entry.display_name.is_empty()
            || !entry.speeds.contains(&entry.default_speed)
            || !entry.reasoning_efforts.iter().all(|value| {
                ["none", "low", "medium", "high", "xhigh", "max"].contains(&value.as_str())
            })
            || !entry
                .speeds
                .iter()
                .all(|value| ["standard", "priority", "flex"].contains(&value.as_str()))
            || !match &entry.default_reasoning {
                Some(value) => entry.reasoning_efforts.contains(value),
                None => entry.reasoning_efforts.is_empty(),
            }
        {
            bail!("Model defaults must be supported capabilities");
        }
    }
    Ok(catalog)
}

fn openai_metadata(model: &str) -> Option<&'static OpenAIModelMetadata> {
    static CATALOG: OnceLock<OpenAIModelCatalog> = OnceLock::new();
    let catalog = CATALOG.get_or_init(|| {
        parse_openai_catalog(include_str!("../Sources/Fritz/ModelCatalog.json"))
            .expect("Invalid bundled OpenAI model catalog")
    });
    catalog.models.get(model)
}

pub(crate) fn client() -> Result<Client> {
    Ok(Client::builder()
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(300))
        .redirect(reqwest::redirect::Policy::none())
        .build()?)
}

pub(crate) fn credential(
    connection: &Connection,
    supplied: Option<&str>,
) -> Result<Option<String>> {
    if supplied.is_none_or(str::is_empty)
        && let Some(saved) = config::load()?
            .connections
            .iter()
            .find(|c| c.id == connection.id)
        && (saved.provider != connection.provider || saved.base_url() != connection.base_url())
    {
        bail!("Enter a key again when changing the provider or endpoint.");
    }
    let key = if let Some(key) = supplied.filter(|k| !k.is_empty()) {
        Some(key.to_owned())
    } else {
        config::key(connection.id)?
    };
    if connection.provider.requires_key() && key.is_none() {
        bail!("Add an API key for {} in Providers.", connection.name);
    }
    Ok(key)
}

pub(crate) fn authenticate(
    request: RequestBuilder,
    kind: ProviderKind,
    key: Option<&str>,
) -> RequestBuilder {
    let request = if kind == ProviderKind::Anthropic {
        request.header("anthropic-version", "2023-06-01")
    } else {
        request
    };
    match (kind, key) {
        (ProviderKind::Anthropic, Some(key)) => request.header("x-api-key", key),
        (ProviderKind::Gemini, Some(key)) => request.header("x-goog-api-key", key),
        (_, Some(key)) => request.bearer_auth(key),
        (_, None) => request,
    }
}

pub(crate) async fn checked(request: RequestBuilder) -> Result<reqwest::Response> {
    let response = request
        .send()
        .await
        .context("Could not connect to the provider.")?;
    check_response(response)
}

fn check_response(response: reqwest::Response) -> Result<reqwest::Response> {
    let status = response.status();
    if !status.is_success() {
        let detail = match status.as_u16() {
            401 | 403 => "The provider rejected access. Check your API key and model permissions.",
            404 => "The endpoint or model was not found. Check the endpoint and model ID.",
            429 => "The provider rate or usage limit was reached. Try again later.",
            400 | 422 => {
                "The provider rejected the request. Check the model and its supported settings."
            }
            _ => "The provider could not complete this request.",
        };
        bail!("{detail} (HTTP {status})");
    }
    Ok(response)
}

pub async fn discover(connection: &Connection, supplied_key: Option<&str>) -> Result<Vec<Model>> {
    connection.validate()?;
    let key = if connection.provider.is_native() {
        None
    } else {
        credential(connection, supplied_key)?
    };
    discover_with_key(connection, key.as_deref()).await
}

/// Discovers a remote catalog using only the supplied credential, without reading Fritz's Keychain.
/// The built-in Fritz provider uses Fritz's default model cache; use ModelStore for another host.
pub async fn discover_with_key(connection: &Connection, key: Option<&str>) -> Result<Vec<Model>> {
    connection.validate()?;
    if connection.provider == ProviderKind::OpenaiDecisions {
        return Ok(vec![Model {
            id: "gpt-6-luna".into(),
            display_name: "GPT-6 Luna".into(),
            created_at: None,
            supports_tools: None,
        }]);
    }
    if connection.provider == ProviderKind::Jev {
        return Ok(vec![Model {
            id: "jev-latest".into(),
            display_name: "Jev".into(),
            created_at: None,
            supports_tools: None,
        }]);
    }
    if connection.provider.is_native() {
        let inventory = if connection.provider == ProviderKind::Ollaya {
            crate::decision::local::ModelStore::configured()?
                .inventory(None)
                .await?
        } else {
            crate::local::models::inventory().await?
        };
        return Ok(inventory["models"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|model| model["installed"] == true)
            .map(|model| Model {
                id: model["id"].as_str().unwrap().into(),
                display_name: model["name"].as_str().unwrap().into(),
                created_at: None,
                supports_tools: None,
            })
            .collect());
    }
    let key = key.filter(|key| !key.is_empty());
    if connection.provider.requires_key() && key.is_none() {
        bail!("Supply an API key for {}.", connection.name);
    }
    let client = client()?;
    let suffix = if connection.provider == ProviderKind::Ollama {
        "api/tags"
    } else {
        "models"
    };
    let endpoint = format!("{}/{suffix}", connection.base_url());
    let mut models = std::collections::BTreeMap::new();
    let mut next_page: Option<String> = None;
    for _ in 0..50 {
        let mut request = client.get(&endpoint).timeout(Duration::from_secs(30));
        if let Some(page) = &next_page {
            request = match connection.provider {
                ProviderKind::Anthropic => request.query(&[("after_id", page)]),
                ProviderKind::Gemini => request.query(&[("pageToken", page)]),
                _ => request,
            };
        }
        let data: Value = checked(authenticate(request, connection.provider, key))
            .await?
            .json()
            .await?;
        let entries = data["data"]
            .as_array()
            .or_else(|| data["models"].as_array())
            .context("The provider returned an invalid model catalog.")?;
        for entry in entries {
            if connection.provider == ProviderKind::Gemini
                && !entry["supportedGenerationMethods"]
                    .as_array()
                    .is_some_and(|methods| methods.iter().any(|v| v == "generateContent"))
            {
                continue;
            }
            let Some(id) = entry["id"].as_str().or_else(|| entry["name"].as_str()) else {
                continue;
            };
            let id = id.trim_start_matches("models/").to_string();
            if connection.provider == ProviderKind::Openai
                && openai_metadata(&id)
                    .is_some_and(|entry| matches!(entry.status, OpenAIModelStatus::Retired))
            {
                continue;
            }
            let mut display_name = entry["display_name"]
                .as_str()
                .or_else(|| entry["displayName"].as_str())
                .or_else(|| entry["name"].as_str())
                .unwrap_or(&id)
                .to_string();
            if connection.provider == ProviderKind::Openai
                && display_name == id
                && let Some(metadata) = openai_metadata(&id)
            {
                display_name.clone_from(&metadata.display_name);
            }
            models.insert(
                id.clone(),
                Model {
                    id,
                    display_name,
                    created_at: entry["created"].as_u64(),
                    supports_tools: entry["supported_parameters"]
                        .as_array()
                        .map(|parameters| parameters.iter().any(|parameter| parameter == "tools")),
                },
            );
        }
        next_page = match connection.provider {
            ProviderKind::Gemini => data["nextPageToken"].as_str().map(str::to_owned),
            ProviderKind::Anthropic if data["has_more"] == true => {
                data["last_id"].as_str().map(str::to_owned)
            }
            _ => None,
        };
        if next_page.is_none() {
            return Ok(models.into_values().collect());
        }
    }
    bail!("The model catalog exceeded the pagination limit.")
}

/// Retrieve the selected Messages model's advertised output ceiling. Never
/// substitute an arbitrary cap for absent provider metadata.
pub async fn output_ceiling(
    connection: &Connection,
    key: Option<&str>,
    model: &str,
) -> Result<usize> {
    connection.validate()?;
    if connection.provider != ProviderKind::Anthropic {
        bail!("Output metadata lookup requires a Messages provider.");
    }
    let mut url = reqwest::Url::parse(&format!("{}/models/", connection.base_url()))?;
    url.path_segments_mut()
        .map_err(|_| anyhow::anyhow!("Invalid provider endpoint"))?
        .pop_if_empty()
        .push(model);
    let metadata: Value = checked(authenticate(
        client()?.get(url).timeout(Duration::from_secs(30)),
        connection.provider,
        key,
    ))
    .await?
    .json()
    .await?;
    metadata["max_tokens"].as_u64().filter(|limit| *limit > 0).and_then(|limit| usize::try_from(limit).ok()).context("Anthropic model metadata must advertise a positive max_tokens ceiling; no smaller output cap will be substituted.")
}

pub(crate) fn payload(
    connection: &Connection,
    request: &ChatRequest,
) -> Result<(&'static str, Value)> {
    if connection.provider.category() == crate::config::ModelCategory::Decision {
        bail!("This is a decision model. Use decisions.evaluate instead of chat.");
    }
    if request.model.trim().is_empty() {
        bail!("Choose a model before sending.");
    }
    if request.messages.is_empty()
        || request.messages.len() > 1000
        || request
            .messages
            .iter()
            .any(|m| !matches!(m.role.as_str(), "user" | "assistant"))
    {
        bail!("A chat requires user and assistant messages (maximum 1,000).");
    }
    if request
        .messages
        .iter()
        .map(|m| m.content.len())
        .sum::<usize>()
        > 2_000_000
    {
        bail!("This conversation is too large. Start a new chat.");
    }
    let messages = || {
        let mut messages = vec![json!({"role":"system", "content":SYSTEM})];
        messages.extend(request.messages.iter().map(|m| json!(m)));
        messages
    };
    Ok(match connection.provider {
        ProviderKind::Openai => {
            let mut body = json!({"model":request.model,"instructions":SYSTEM,"input":request.messages,"stream":true,"store":false});
            let model = request.model.to_lowercase();
            let metadata = openai_metadata(&model);
            if metadata.is_some_and(|entry| matches!(entry.status, OpenAIModelStatus::Retired)) {
                bail!("This model is retired. Choose another model.");
            }
            if let Some(effort) = &request.effort {
                let supported =
                    metadata.is_some_and(|entry| entry.reasoning_efforts.contains(effort));
                if !supported {
                    bail!("Unsupported reasoning effort.");
                }
                body["reasoning"] = json!({"effort":effort});
            }
            if let Some(speed) = &request.speed {
                if speed != "standard"
                    && !metadata.is_some_and(|entry| entry.speeds.contains(speed))
                {
                    bail!("Unsupported speed for this model.");
                }
                match speed.as_str() {
                    "priority" | "flex" => body["service_tier"] = json!(speed),
                    "standard" => body["service_tier"] = json!("default"),
                    _ => bail!("Unsupported speed."),
                }
            }
            ("responses", body)
        }
        ProviderKind::Anthropic => (
            "messages",
            json!({"model":request.model,"system":SYSTEM,"messages":request.messages,"max_tokens":8192,"stream":true}),
        ),
        ProviderKind::Gemini => (
            "gemini",
            json!({"systemInstruction":{"parts":[{"text":SYSTEM}]},"contents":request.messages.iter().map(|m| json!({"role":if m.role=="assistant" {"model"} else {"user"},"parts":[{"text":m.content}]})).collect::<Vec<_>>() }),
        ),
        ProviderKind::Ollama => (
            "api/chat",
            json!({"model":request.model,"messages":messages(),"stream":true}),
        ),
        _ => (
            "chat/completions",
            json!({"model":request.model,"messages":messages(),"stream":true}),
        ),
    })
}

#[derive(Default)]
struct StreamDecoder {
    buffer: Vec<u8>,
}
impl StreamDecoder {
    fn push(&mut self, bytes: &[u8]) -> Result<Vec<String>> {
        self.buffer.extend_from_slice(bytes);
        if self.buffer.len() > 4_000_000 {
            bail!("Provider stream event exceeded the size limit.");
        }
        let mut lines = Vec::new();
        while let Some(end) = self.buffer.iter().position(|c| *c == b'\n') {
            let bytes = self.buffer.drain(..=end).collect::<Vec<_>>();
            lines.push(String::from_utf8(bytes)?.trim().to_string());
        }
        Ok(lines)
    }
}

fn decode_event(kind: ProviderKind, value: &Value, emit: &impl Fn(Value)) -> Result<bool> {
    if !value["error"].is_null()
        || matches!(
            value["type"].as_str(),
            Some("error" | "response.failed" | "response.incomplete")
        )
    {
        bail!("The provider interrupted the response. Check your model settings and try again.");
    }
    let mut complete = false;
    match kind {
        ProviderKind::Openai => {
            if value["type"] == "response.output_text.delta"
                || value["type"] == "response.refusal.delta"
            {
                if let Some(text) = value["delta"].as_str() {
                    emit(json!({"type":"delta","text":text}));
                }
            } else if value["type"] == "response.completed" {
                emit(json!({"type":"usage","usage":value["response"]["usage"]}));
                complete = true;
            }
        }
        ProviderKind::Anthropic => {
            if value["delta"]["type"] == "text_delta"
                && let Some(text) = value["delta"]["text"].as_str()
            {
                emit(json!({"type":"delta","text":text}));
            }
            if !value["message"]["usage"].is_null() {
                emit(json!({"type":"usage","usage":value["message"]["usage"]}));
            }
            if !value["usage"].is_null() {
                emit(json!({"type":"usage","usage":value["usage"]}));
            }
            complete = value["type"] == "message_stop";
        }
        ProviderKind::Gemini => {
            if let Some(parts) = value["candidates"][0]["content"]["parts"].as_array() {
                for part in parts {
                    if part["thought"] != true
                        && let Some(text) = part["text"].as_str()
                    {
                        emit(json!({"type":"delta","text":text}));
                    }
                }
            }
            if !value["usageMetadata"].is_null() {
                emit(json!({"type":"usage","usage":value["usageMetadata"]}));
            }
            complete = value["candidates"][0]["finishReason"].is_string();
            if value["promptFeedback"]["blockReason"].is_string() {
                bail!("The provider blocked this prompt.");
            }
        }
        ProviderKind::Ollama => {
            if let Some(text) = value["message"]["content"].as_str() {
                emit(json!({"type":"delta","text":text}));
            }
            complete = value["done"] == true;
            if complete {
                emit(
                    json!({"type":"usage","usage":{"input_tokens":value["prompt_eval_count"],"output_tokens":value["eval_count"]}}),
                );
            }
        }
        _ => {
            if let Some(text) = value["choices"][0]["delta"]["content"].as_str() {
                emit(json!({"type":"delta","text":text}));
            }
            if !value["usage"].is_null() {
                emit(json!({"type":"usage","usage":value["usage"]}));
            }
            complete = value["choices"][0]["finish_reason"].is_string();
        }
    }
    Ok(complete)
}

/// Retry only the initial connection, once and for at most 15 seconds. No
/// streamed text or tool calls are replayed. Error-body hints are bounded and
/// never returned to the host or logged.
async fn stream_response(request: RequestBuilder) -> Result<reqwest::Response> {
    let retry = request
        .try_clone()
        .context("Provider request cannot be replayed.")?;
    let response = request
        .send()
        .await
        .context("Could not connect to the provider.")?;
    if response.status().as_u16() != 429 {
        return check_response(response);
    }
    let header_delay = response
        .headers()
        .get("retry-after")
        .and_then(|value| value.to_str().ok())
        .and_then(duration_at_start);
    let mut body = Vec::new();
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        if body.len().saturating_add(chunk.len()) > 64 * 1024 {
            bail!("The provider rate limit response exceeded its size limit (HTTP 429).");
        }
        body.extend_from_slice(&chunk);
    }
    let delay = header_delay
        .or_else(|| {
            std::str::from_utf8(&body)
                .ok()
                .and_then(retry_delay_from_provider_body)
        })
        .unwrap_or(Duration::from_secs(1));
    if delay > Duration::from_secs(15) {
        bail!("The provider requested a rate-limit wait longer than 15 seconds (HTTP 429).");
    }
    tokio::time::sleep(delay).await;
    check_response(
        retry
            .send()
            .await
            .context("Could not connect to the provider.")?,
    )
}

fn retry_delay_from_provider_body(body: &str) -> Option<Duration> {
    if let Ok(value) = serde_json::from_str::<Value>(body) {
        for pointer in [
            "/retry_after_ms",
            "/error/retry_after_ms",
            "/retry-after-ms",
            "/error/retry-after-ms",
        ] {
            if let Some(delay) = value.pointer(pointer).and_then(duration_from_milliseconds) {
                return Some(delay);
            }
        }
        for pointer in [
            "/retry_after",
            "/error/retry_after",
            "/retry_after_seconds",
            "/error/retry_after_seconds",
            "/retry-after",
            "/error/retry-after",
        ] {
            if let Some(delay) = value.pointer(pointer).and_then(duration_from_seconds) {
                return Some(delay);
            }
        }
        for pointer in ["/error/message", "/message"] {
            if let Some(delay) = value
                .pointer(pointer)
                .and_then(Value::as_str)
                .and_then(duration_from_retry_message)
            {
                return Some(delay);
            }
        }
    }
    duration_from_retry_message(body)
}

fn duration_from_milliseconds(value: &Value) -> Option<Duration> {
    value
        .as_f64()
        .and_then(|milliseconds| duration_from_secs_f64(milliseconds / 1_000.0))
        .or_else(|| {
            let value = value.as_str()?;
            value
                .parse::<f64>()
                .ok()
                .and_then(|milliseconds| duration_from_secs_f64(milliseconds / 1_000.0))
                .or_else(|| duration_at_start(value))
        })
}

fn duration_from_seconds(value: &Value) -> Option<Duration> {
    value
        .as_f64()
        .and_then(duration_from_secs_f64)
        .or_else(|| value.as_str().and_then(duration_at_start))
}

fn duration_from_retry_message(message: &str) -> Option<Duration> {
    let message = message.to_ascii_lowercase();
    ["try again in", "retry after"]
        .into_iter()
        .find_map(|marker| {
            let start = message.find(marker)? + marker.len();
            duration_at_start(message[start..].trim_start())
        })
}

fn duration_at_start(value: &str) -> Option<Duration> {
    let number_end = value
        .char_indices()
        .take_while(|(_, character)| character.is_ascii_digit() || *character == '.')
        .map(|(index, character)| index + character.len_utf8())
        .last()?;
    let amount = value[..number_end].parse::<f64>().ok()?;
    let unit = value[number_end..].trim_start().to_ascii_lowercase();
    let seconds = if unit.starts_with("ms") {
        amount / 1_000.0
    } else if unit.starts_with('m') {
        amount * 60.0
    } else {
        amount
    };
    duration_from_secs_f64(seconds)
}

fn duration_from_secs_f64(seconds: f64) -> Option<Duration> {
    (seconds.is_finite() && seconds >= 0.0)
        .then(|| Duration::try_from_secs_f64(seconds).ok())
        .flatten()
}

pub(crate) async fn stream_body(
    connection: &Connection,
    key: Option<&str>,
    model: &str,
    suffix: &str,
    body: &Value,
    emit: impl Fn(Value),
    observe: impl Fn(&Value) -> Result<()>,
) -> Result<()> {
    let mut url = reqwest::Url::parse(&format!("{}/{}", connection.base_url(), suffix))?;
    if connection.provider == ProviderKind::Gemini {
        url = reqwest::Url::parse(&format!("{}/models/", connection.base_url()))?;
        url.path_segments_mut()
            .map_err(|_| anyhow::anyhow!("Invalid endpoint"))?
            .pop_if_empty()
            .push(&format!("{model}:streamGenerateContent"));
        url.query_pairs_mut().append_pair("alt", "sse");
    }
    let response = stream_response(authenticate(
        client()?.post(url).json(body),
        connection.provider,
        key,
    ))
    .await?;
    let mut stream = response.bytes_stream();
    let mut decoder = StreamDecoder::default();
    let mut complete = false;
    let mut received = 0;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        received += chunk.len();
        if received > 8_000_000 {
            bail!("Provider response exceeded the size limit.");
        }
        for line in decoder.push(&chunk)? {
            let data = if connection.provider == ProviderKind::Ollama {
                line.as_str()
            } else {
                match line.strip_prefix("data:") {
                    Some(data) => data.trim(),
                    None => continue,
                }
            };
            if data == "[DONE]" {
                complete = true;
                continue;
            }
            if data.is_empty() {
                continue;
            }
            let value: Value =
                serde_json::from_str(data).context("Invalid provider stream event.")?;
            complete |= decode_event(connection.provider, &value, &emit)?;
            observe(&value)?;
        }
    }
    if !decoder.buffer.is_empty() {
        let mut tail = decoder.buffer.clone();
        tail.push(b'\n');
        decoder.buffer.clear();
        for line in decoder.push(&tail)? {
            let data = line.strip_prefix("data:").unwrap_or(&line).trim();
            if data == "[DONE]" {
                complete = true;
            } else if !data.is_empty() {
                let value = serde_json::from_str(data)?;
                complete |= decode_event(connection.provider, &value, &emit)?;
                observe(&value)?;
            }
        }
    }
    if !complete {
        bail!("The provider connection ended before the response finished.");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn initial_rate_limits_retry_the_same_request_once_and_respect_long_waits() {
        use std::io::{Read, Write};
        for (status, retry_after, expected_requests) in
            [(429, "0", 2), (429, "16", 1), (401, "0", 1)]
        {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            listener.set_nonblocking(true).unwrap();
            let address = listener.local_addr().unwrap();
            let server = std::thread::spawn(move || {
                let mut requests = Vec::new();
                for index in 0..expected_requests {
                    let deadline = std::time::Instant::now() + Duration::from_secs(5);
                    let mut stream = loop {
                        match listener.accept() {
                            Ok((stream, _)) => break stream,
                            Err(error)
                                if error.kind() == std::io::ErrorKind::WouldBlock
                                    && std::time::Instant::now() < deadline =>
                            {
                                std::thread::sleep(Duration::from_millis(5))
                            }
                            Err(error) => panic!("Missing provider request: {error}"),
                        }
                    };
                    // macOS inherits the listener's nonblocking mode on accept.
                    stream.set_nonblocking(false).unwrap();
                    stream
                        .set_read_timeout(Some(Duration::from_secs(2)))
                        .unwrap();
                    let mut bytes = Vec::new();
                    let mut buffer = [0; 4096];
                    loop {
                        let count = stream.read(&mut buffer).unwrap();
                        assert!(count > 0);
                        bytes.extend_from_slice(&buffer[..count]);
                        let text = String::from_utf8_lossy(&bytes);
                        if let Some((headers, body)) = text.split_once("\r\n\r\n") {
                            let length = headers
                                .lines()
                                .find_map(|line| {
                                    line.to_lowercase()
                                        .strip_prefix("content-length:")
                                        .map(|value| value.trim().parse::<usize>().unwrap())
                                })
                                .unwrap();
                            if body.len() >= length {
                                break;
                            }
                        }
                    }
                    requests.push(bytes);
                    let code = if index == 0 { status } else { 200 };
                    let response = format!(
                        "HTTP/1.1 {code} Test\r\nRetry-After: {retry_after}\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{{}}"
                    );
                    stream.write_all(response.as_bytes()).unwrap();
                }
                requests
            });
            let result = stream_response(
                client()
                    .unwrap()
                    .post(format!("http://{address}/chat"))
                    .json(&json!({"messages":[{"role":"user","content":"Continue"}]})),
            )
            .await;
            assert_eq!(result.is_ok(), expected_requests == 2);
            let requests = server.join().unwrap();
            assert_eq!(requests.len(), expected_requests);
            if requests.len() == 2 {
                assert_eq!(requests[0], requests[1]);
            }
        }
        assert_eq!(
            retry_delay_from_provider_body(r#"{"error":{"message":"Try again in 250ms"}}"#),
            Some(Duration::from_millis(250))
        );
        assert_eq!(
            retry_delay_from_provider_body(r#"{"retry_after":0.125}"#),
            Some(Duration::from_millis(125))
        );
    }

    #[tokio::test]
    async fn jev_has_a_decision_catalog_and_cannot_chat() {
        let connection = Connection {
            id: uuid::Uuid::new_v4(),
            name: "Jev".into(),
            provider: ProviderKind::Jev,
            base_url: None,
            model_id: "jev-latest".into(),
        };
        let models = discover_with_key(&connection, None).await.unwrap();
        assert_eq!(models[0].id, "jev-latest");
        let request = ChatRequest {
            connection_id: connection.id.to_string(),
            model: "jev-latest".into(),
            messages: vec![Message {
                role: "user".into(),
                content: "Hi".into(),
            }],
            effort: None,
            speed: None,
            project_path: None,
            max_turns: 24,
        };
        assert!(payload(&connection, &request).is_err());
    }
    #[test]
    fn fragmented_utf8_and_crlf_stream() {
        let mut decoder = StreamDecoder::default();
        let data = "data: {\"text\":\"café\"}\r\n\r\n".as_bytes();
        let mut lines = vec![];
        for byte in data {
            lines.extend(decoder.push(&[*byte]).unwrap());
        }
        assert_eq!(lines, vec!["data: {\"text\":\"café\"}", ""]);
    }
    #[test]
    fn adapters_handle_completion_and_errors() {
        let emit = |_| {};
        assert!(
            decode_event(
                ProviderKind::Openai,
                &json!({"type":"response.completed"}),
                &emit
            )
            .unwrap()
        );
        assert!(
            decode_event(
                ProviderKind::Anthropic,
                &json!({"type":"message_stop"}),
                &emit
            )
            .unwrap()
        );
        assert!(
            decode_event(
                ProviderKind::Gemini,
                &json!({"candidates":[{"finishReason":"STOP"}]}),
                &emit
            )
            .unwrap()
        );
        assert!(decode_event(ProviderKind::Ollama, &json!({"done":true}), &emit).unwrap());
        assert!(
            decode_event(
                ProviderKind::Openai,
                &json!({"type":"response.failed"}),
                &emit
            )
            .is_err()
        );
    }
    #[test]
    fn openai_catalog_rejects_incompatible_schema_and_unsupported_defaults() {
        let valid = json!({"schemaVersion":1,"revision":1,"models":{"test":{
            "displayName":"Test", "status":"active", "reasoningEfforts":["medium"],
            "speeds":["standard"], "defaultReasoning":"medium", "defaultSpeed":"standard"
        }}});
        for status in ["active", "deprecated", "retired"] {
            let mut data = valid.clone();
            data["models"]["test"]["status"] = json!(status);
            assert!(parse_openai_catalog(&json!({"reviewed_openai":data}).to_string()).is_ok());
        }
        for (field, value) in [
            ("status", json!("unknown")),
            ("defaultReasoning", json!("high")),
            ("defaultReasoning", Value::Null),
            ("defaultSpeed", json!("priority")),
            ("reasoningEfforts", json!(["medium", "future"])),
            ("speeds", json!(["standard", "future"])),
        ] {
            let mut data = valid.clone();
            data["models"]["test"][field] = value;
            assert!(
                parse_openai_catalog(&json!({"reviewed_openai":data}).to_string()).is_err(),
                "{field}"
            );
        }
        let mut data = valid.clone();
        data["schemaVersion"] = json!(2);
        assert!(parse_openai_catalog(&json!({"reviewed_openai":data}).to_string()).is_err());
        data = valid.clone();
        data["models"]["test"]
            .as_object_mut()
            .unwrap()
            .remove("defaultReasoning");
        assert!(parse_openai_catalog(&json!({"reviewed_openai":data}).to_string()).is_err());
        data["models"]["test"]["defaultReasoning"] = Value::Null;
        data["models"]["test"]["reasoningEfforts"] = json!([]);
        assert!(parse_openai_catalog(&json!({"reviewed_openai":data}).to_string()).is_ok());
    }

    #[test]
    fn reviewed_openai_options_reach_the_api_and_reject_unsupported_efforts() {
        let connection = Connection {
            id: uuid::Uuid::new_v4(),
            name: "test".into(),
            provider: ProviderKind::Openai,
            base_url: Some("http://localhost/v1".into()),
            model_id: String::new(),
        };
        let mut request = ChatRequest {
            connection_id: connection.id.to_string(),
            model: "gpt-6.1-sol".into(),
            messages: vec![Message {
                role: "user".into(),
                content: "Hi".into(),
            }],
            effort: Some("max".into()),
            speed: Some("priority".into()),
            project_path: None,
            max_turns: 24,
        };
        for (model, effort, speed) in [
            ("gpt-6.1-sol", "max", "priority"),
            ("gpt-6-astra", "xhigh", "flex"),
            ("gpt-6-luna", "none", "standard"),
        ] {
            request.model = model.into();
            request.effort = Some(effort.into());
            request.speed = Some(speed.into());
            let (path, body) = payload(&connection, &request).unwrap();
            assert_eq!(path, "responses");
            assert_eq!(body["model"], model);
            assert_eq!(body["reasoning"]["effort"], effort);
            if speed != "standard" {
                assert_eq!(body["service_tier"], speed);
            } else {
                assert_eq!(body["service_tier"], "default");
            }
        }
        request.model = "gpt-6.1-sol".into();
        request.effort = Some("none".into());
        assert!(
            payload(&connection, &request)
                .unwrap_err()
                .to_string()
                .contains("Unsupported reasoning effort")
        );
    }

    #[test]
    fn compatible_requests_do_not_receive_openai_options() {
        let connection = Connection {
            id: uuid::Uuid::new_v4(),
            name: "test".into(),
            provider: ProviderKind::OpenaiCompatible,
            base_url: Some("http://localhost/v1".into()),
            model_id: String::new(),
        };
        let request = ChatRequest {
            connection_id: connection.id.to_string(),
            model: "custom".into(),
            messages: vec![Message {
                role: "user".into(),
                content: "Hi".into(),
            }],
            effort: Some("high".into()),
            speed: Some("priority".into()),
            project_path: None,
            max_turns: 24,
        };
        let (path, body) = payload(&connection, &request).unwrap();
        assert_eq!(path, "chat/completions");
        assert!(body.get("reasoning").is_none());
        assert!(body.get("service_tier").is_none());
        assert_eq!(body["messages"][0]["role"], "system");
    }
}
