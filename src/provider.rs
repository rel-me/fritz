pub(crate) mod model_context;
pub use fritz_provider::{ContextOverflow, ContextSource, ModelContext};

use crate::config::{self, Connection, ProviderKind};
use anyhow::{Context, Result, bail};
pub use fritz_provider::Model;
use fritz_provider::{OpenAIModelStatus, ProviderApi, openai_metadata};
pub(crate) use fritz_provider::{checked, client};
use reqwest::RequestBuilder;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{collections::HashMap, sync::OnceLock, time::Duration};

pub(crate) const SYSTEM: &str = "You are Fritz, a personal assistant in a native macOS app. Help the user answer questions, think through everyday tasks, organize ideas, and draft text. Be clear and accurate. You have no access to personal data beyond what the user shares in this conversation. No tools are available for this request. Do not claim to inspect or change files, run local processes, or access other apps or services.";

#[derive(Clone, Deserialize, Serialize)]
pub struct Message {
    pub role: String,
    pub content: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tools: Vec<HistoricalTool>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HistoricalTool {
    pub id: String,
    pub name: String,
    pub arguments: String,
    pub result: String,
    pub failed: bool,
}

impl HistoricalTool {
    pub(crate) fn exchange(&self) -> Result<(crate::harness::Call, fritz_harness::ToolResult)> {
        let arguments: Value = serde_json::from_str(&self.arguments)?;
        anyhow::ensure!(
            arguments.is_object(),
            "Historical tool arguments must be an object."
        );
        let result = serde_json::from_str(&self.result)?;
        Ok((
            crate::harness::Call {
                id: self.id.clone(),
                name: self.name.clone(),
                arguments: self.arguments.clone(),
            },
            fritz_harness::ToolResult::json(result, self.failed),
        ))
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatRequest {
    pub connection_id: String,
    pub model: String,
    pub messages: Vec<Message>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub history_version: Option<u8>,
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

impl From<ProviderKind> for ProviderApi {
    fn from(kind: ProviderKind) -> Self {
        match kind {
            ProviderKind::Openai => Self::Openai,
            ProviderKind::Anthropic => Self::Anthropic,
            ProviderKind::Gemini => Self::Gemini,
            ProviderKind::Openrouter => Self::Openrouter,
            ProviderKind::Ollama => Self::Ollama,
            _ => Self::Compatible,
        }
    }
}

pub(crate) fn authenticate(
    request: RequestBuilder,
    kind: ProviderKind,
    key: Option<&str>,
) -> RequestBuilder {
    fritz_provider::authenticate(request, kind.into(), key)
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

#[derive(Deserialize)]
pub(crate) struct RemoteDecisionModel {
    pub id: String,
    name: String,
}

pub(crate) fn remote_decision_model(
    provider: ProviderKind,
) -> Option<&'static RemoteDecisionModel> {
    #[derive(Deserialize)]
    struct Catalog {
        remote_decision: HashMap<String, RemoteDecisionModel>,
    }
    static MODELS: OnceLock<HashMap<String, RemoteDecisionModel>> = OnceLock::new();
    let key = match provider {
        ProviderKind::OpenaiDecisions => "openai-decisions",
        ProviderKind::Jev => "jev",
        _ => return None,
    };
    let models = MODELS.get_or_init(|| {
        serde_json::from_str::<Catalog>(crate::MODEL_CATALOG_JSON)
            .expect("checked-in remote decision catalog")
            .remote_decision
    });
    Some(
        models
            .get(key)
            .expect("remote decision provider in catalog"),
    )
}

/// Discovers a remote catalog using only the supplied credential, without reading Fritz's Keychain.
/// The built-in Fritz provider uses Fritz's default model cache; use ModelStore for another host.
pub async fn discover_with_key(connection: &Connection, key: Option<&str>) -> Result<Vec<Model>> {
    connection.validate()?;
    if let Some(decision) = remote_decision_model(connection.provider) {
        return Ok(vec![Model {
            id: decision.id.clone(),
            display_name: decision.name.clone(),
            created_at: None,
            supports_tools: None,
            context: model_context::bundled(connection, &decision.id),
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
                context: model_context::bundled(connection, model["id"].as_str().unwrap()),
            })
            .collect());
    }
    let key = key.filter(|key| !key.is_empty());
    if connection.provider.requires_key() && key.is_none() {
        bail!("Supply an API key for {}.", connection.name);
    }
    let mut models =
        fritz_provider::discover(connection.provider.into(), connection.base_url(), key).await?;
    for model in &mut models {
        if matches!(model.context.source, ContextSource::Unknown) {
            model.context = model_context::bundled(connection, &model.id);
        }
    }
    Ok(models)
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
    if let Some(version) = request.history_version {
        anyhow::ensure!(
            matches!(version, 1 | 2),
            "Unsupported chat history version."
        );
        let max = if version == 2 {
            1_000_000
        } else if connection.provider == ProviderKind::Fritz {
            4_800
        } else {
            16_000
        };
        anyhow::ensure!(
            serde_json::to_vec(&request.messages)?.len() <= max,
            "Chat history exceeds the workspace context limit."
        );
    }
    let mut tool_ids = std::collections::HashSet::new();
    for message in &request.messages {
        if message.tools.is_empty() {
            continue;
        }
        anyhow::ensure!(
            matches!(request.history_version, Some(1 | 2))
                && message.role == "assistant"
                && connection.provider != ProviderKind::Gemini
                && message.tools.len() <= 64,
            "Invalid historical tool exchange."
        );
        for tool in &message.tools {
            anyhow::ensure!(
                tool.name.len() <= 64
                    && !tool.name.is_empty()
                    && tool
                        .name
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
                    && tool.id.len() <= 64
                    && !tool.id.is_empty()
                    && tool
                        .id
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
                    && tool_ids.insert(&tool.id),
                "Invalid historical tool identity."
            );
            tool.exchange()?;
        }
    }
    let plain_messages: Vec<_> = request
        .messages
        .iter()
        .map(|m| json!({"role":m.role,"content":m.content}))
        .collect();
    let messages = || {
        let mut messages = vec![json!({"role":"system", "content":SYSTEM})];
        messages.extend(plain_messages.iter().cloned());
        messages
    };
    Ok(match connection.provider {
        ProviderKind::Openai => {
            let mut body =
                fritz_provider::responses_payload(&request.model, SYSTEM, plain_messages);
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
            json!({"model":request.model,"system":SYSTEM,"messages":plain_messages,"max_tokens":8192,"stream":true}),
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
            fritz_provider::chat_completions_payload(&request.model, SYSTEM, &plain_messages),
        ),
    })
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
    let kind = connection.provider.into();
    let url = fritz_provider::chat_endpoint(kind, connection.base_url(), model, suffix)?;
    fritz_provider::stream_body(kind, url, key, body, emit, observe).await
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
            history_version: None,
            connection_id: connection.id.to_string(),
            model: "jev-latest".into(),
            messages: vec![Message {
                role: "user".into(),
                content: "Hi".into(),
                tools: vec![],
            }],
            effort: None,
            speed: None,
            project_path: None,
            max_turns: 24,
        };
        assert!(payload(&connection, &request).is_err());
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
            history_version: None,
            connection_id: connection.id.to_string(),
            model: "gpt-6.1-sol".into(),
            messages: vec![Message {
                role: "user".into(),
                content: "Hi".into(),
                tools: vec![],
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
            history_version: None,
            connection_id: connection.id.to_string(),
            model: "custom".into(),
            messages: vec![Message {
                role: "user".into(),
                content: "Hi".into(),
                tools: vec![],
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
