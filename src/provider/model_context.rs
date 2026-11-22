use crate::config::{Connection, ProviderKind};
use fritz_provider::{ContextSource, ModelContext};
use rig_core::{catalog::Catalog, providers::registry::ProviderId};
use serde_json::Value;
use std::sync::OnceLock;

fn tokens(value: &Value) -> Option<u32> {
    value
        .as_u64()
        .and_then(|value| u32::try_from(value).ok())
        .filter(|&value| value > 0)
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
