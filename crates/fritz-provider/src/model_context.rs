use crate::ProviderApi;
use serde::{Deserialize, Serialize};
use serde_json::Value;

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

pub(crate) fn from_listing(provider: ProviderApi, model: &Value) -> Option<ModelContext> {
    let limits = match provider {
        ProviderApi::Anthropic => ModelContext {
            input_tokens: tokens(&model["max_input_tokens"]),
            output_tokens: tokens(&model["max_tokens"]),
            ..Default::default()
        },
        ProviderApi::Gemini => ModelContext {
            input_tokens: tokens(&model["inputTokenLimit"]),
            output_tokens: tokens(&model["outputTokenLimit"]),
            ..Default::default()
        },
        ProviderApi::Openrouter => ModelContext {
            window_tokens: tokens(&model["context_length"]),
            effective_window_tokens: tokens(&model["top_provider"]["context_length"]),
            output_tokens: tokens(&model["top_provider"]["max_completion_tokens"]),
            ..Default::default()
        },
        ProviderApi::Openai | ProviderApi::Compatible => ModelContext {
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

pub(crate) fn from_ollama_show(model: &Value) -> Option<ModelContext> {
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

pub(crate) fn ollama_active_windows(data: &Value) -> std::collections::HashMap<String, u32> {
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
