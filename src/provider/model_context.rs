use crate::config::{Connection, ProviderKind};
use rig_core::{catalog::Catalog, providers::registry::ProviderId};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::sync::OnceLock;

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ModelContext {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub window_tokens: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input_tokens: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output_tokens: Option<u32>,
    /// An advertised route or configured runtime limit, where available.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub effective_window_tokens: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub automatic_window_tokens: Option<u32>,
    pub source: ContextSource,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ContextSource {
    Provider,
    Catalog,
    Fritz,
    #[default]
    Unknown,
}

fn tokens(value: &Value) -> Option<u32> {
    value
        .as_u64()
        .and_then(|value| u32::try_from(value).ok())
        .filter(|&value| value > 0)
}

fn reported(mut limits: ModelContext) -> Option<ModelContext> {
    limits.source = ContextSource::Provider;
    (limits
        .window_tokens
        .or(limits.input_tokens)
        .or(limits.output_tokens)
        .or(limits.effective_window_tokens)
        .is_some())
    .then_some(limits)
}

pub(super) fn from_listing(provider: ProviderKind, model: &Value) -> Option<ModelContext> {
    let limits = match provider {
        ProviderKind::Anthropic => ModelContext {
            input_tokens: tokens(&model["max_input_tokens"]),
            output_tokens: tokens(&model["max_tokens"]),
            ..Default::default()
        },
        ProviderKind::Gemini => ModelContext {
            input_tokens: tokens(&model["inputTokenLimit"]),
            output_tokens: tokens(&model["outputTokenLimit"]),
            ..Default::default()
        },
        ProviderKind::Openrouter => ModelContext {
            window_tokens: tokens(&model["context_length"]),
            effective_window_tokens: tokens(&model["top_provider"]["context_length"]),
            output_tokens: tokens(&model["top_provider"]["max_completion_tokens"]),
            ..Default::default()
        },
        ProviderKind::Openai | ProviderKind::OpenaiCompatible => ModelContext {
            window_tokens: tokens(&model["context_window"])
                .or_else(|| tokens(&model["context_length"]))
                .or_else(|| tokens(&model["max_model_len"])),
            input_tokens: tokens(&model["max_input_tokens"]),
            output_tokens: tokens(&model["max_output_tokens"]),
            ..Default::default()
        },
        _ => return None,
    };
    reported(limits)
}

pub(super) fn from_ollama_show(model: &Value) -> Option<ModelContext> {
    let information = &model["model_info"];
    let window_tokens = information["general.architecture"]
        .as_str()
        .and_then(|architecture| tokens(&information[format!("{architecture}.context_length")]));
    let effective_window_tokens = model["parameters"].as_str().and_then(|parameters| {
        parameters.lines().find_map(|line| {
            let (name, value) = line.trim().split_once(char::is_whitespace)?;
            if name != "num_ctx" {
                return None;
            }
            value.trim().parse::<u32>().ok().filter(|&value| value > 0)
        })
    });
    reported(ModelContext {
        window_tokens,
        effective_window_tokens,
        ..Default::default()
    })
}

pub(super) fn ollama_active_windows(data: &Value) -> std::collections::HashMap<String, u32> {
    data["models"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|model| {
            let id = model["name"].as_str().or_else(|| model["model"].as_str())?;
            Some((id.to_owned(), tokens(&model["context_length"])?))
        })
        .collect()
}

pub(crate) fn bundled(connection: &Connection, model: &str) -> ModelContext {
    static CATALOG: OnceLock<Value> = OnceLock::new();
    let catalog = CATALOG.get_or_init(|| {
        serde_json::from_str(crate::MODEL_CATALOG_JSON).expect("checked-in model catalog")
    });
    let local_entry = |category: &str| {
        catalog[category]["models"]
            .as_array()
            .and_then(|models| models.iter().find(|row| row["id"] == model))
    };
    match connection.provider {
        ProviderKind::Fritz => {
            return ModelContext {
                window_tokens: local_entry("local_chat")
                    .and_then(|row| tokens(&row["limit"]["context"])),
                automatic_window_tokens: local_entry("local_chat")
                    .and_then(|row| tokens(&row["limit"]["automatic_target"])),
                source: ContextSource::Fritz,
                ..Default::default()
            };
        }
        ProviderKind::Ollaya => {
            let input_tokens =
                local_entry("local_decision").and_then(|row| tokens(&row["limit"]["input"]));
            return ModelContext {
                input_tokens,
                source: if input_tokens.is_some() {
                    ContextSource::Fritz
                } else {
                    ContextSource::Unknown
                },
                ..Default::default()
            };
        }
        _ => {}
    }
    let provider = match connection.provider {
        ProviderKind::Openai => "openai",
        ProviderKind::Anthropic => "anthropic",
        ProviderKind::Gemini => "gemini",
        ProviderKind::Openrouter => "openrouter",
        _ => return ModelContext::default(),
    };
    if connection.base_url() != connection.provider.default_url() {
        return ModelContext::default();
    }
    let entry = &catalog["model_info"]["providers"][provider]["models"][model]["limit"];
    let reviewed = if provider == "openai" {
        &catalog["reviewed_openai"]["models"][model]["limit"]
    } else {
        &Value::Null
    };
    let vendor = if provider == "gemini" {
        "google"
    } else {
        provider
    };
    let rig = ProviderId::catalog(vendor)
        .and_then(|provider| Catalog::builtin().get(provider, model))
        .map(|entry| entry.spec);
    let window_tokens = tokens(&reviewed["context"])
        .or_else(|| tokens(&entry["context"]))
        .or_else(|| rig.and_then(|spec| spec.context_window));
    let input_tokens =
        tokens(&entry["input"]).or_else(|| rig.and_then(|spec| spec.max_input_tokens));
    let output_tokens = tokens(&reviewed["output"])
        .or_else(|| tokens(&entry["output"]))
        .or_else(|| rig.and_then(|spec| spec.output_limit()));
    ModelContext {
        window_tokens,
        input_tokens,
        output_tokens,
        source: if window_tokens.or(input_tokens).or(output_tokens).is_some() {
            ContextSource::Catalog
        } else {
            ContextSource::Unknown
        },
        ..Default::default()
    }
}
