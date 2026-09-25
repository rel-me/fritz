use crate::config::{self, Connection, ProviderKind};
use anyhow::{Context, Result, bail};
use futures_util::StreamExt;
use reqwest::{Client, RequestBuilder};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::time::Duration;

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
    let key = if connection.provider == ProviderKind::Fritz {
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
    if connection.provider == ProviderKind::Jev {
        return Ok(vec![Model {
            id: "jev-latest".into(),
            display_name: "Jev".into(),
        }]);
    }
    if connection.provider == ProviderKind::Fritz {
        let inventory = crate::local::models::inventory().await?;
        return Ok(inventory["models"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|model| model["installed"] == true)
            .map(|model| Model {
                id: model["id"].as_str().unwrap().into(),
                display_name: model["name"].as_str().unwrap().into(),
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
            let display_name = entry["display_name"]
                .as_str()
                .or_else(|| entry["displayName"].as_str())
                .or_else(|| entry["name"].as_str())
                .unwrap_or(&id)
                .to_string();
            models.insert(id.clone(), Model { id, display_name });
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

pub(crate) fn payload(
    connection: &Connection,
    request: &ChatRequest,
) -> Result<(&'static str, Value)> {
    if connection.provider == ProviderKind::Jev {
        bail!("Jev is a decision model. Use decisions.evaluate instead of chat.");
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
            let fixed = model.contains("-pro")
                || model.contains("deep-research")
                || model.contains("-chat");
            let reasoning = model.starts_with("gpt-5")
                || model.as_bytes().get(1).is_some_and(u8::is_ascii_digit)
                    && model.starts_with('o');
            if reasoning
                && !fixed
                && let Some(effort) = &request.effort
            {
                if !["low", "medium", "high"].contains(&effort.as_str()) {
                    bail!("Unsupported reasoning effort.");
                }
                body["reasoning"] = json!({"effort":effort});
            }
            if !fixed && let Some(speed) = &request.speed {
                match speed.as_str() {
                    "priority" | "flex" => body["service_tier"] = json!(speed),
                    "standard" => {}
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
    let response = checked(authenticate(
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
