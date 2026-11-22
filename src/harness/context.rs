//! Rig context budgeting for Fritz's native provider sessions.
use crate::config::{Connection, ProviderKind};
use crate::provider::{ModelContext, model_context};
use fritz_harness::message::{Message, UserContent};
use rig_memory::{CompactionSettings, find_cut_point, request_tokens};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

#[derive(Clone, Copy, Default, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub struct ContextSettings {
    pub automatic_compaction: Option<bool>,
    pub context_tokens: Option<u64>,
    pub reserve_tokens: Option<u64>,
    pub keep_recent_tokens: Option<u64>,
    pub has_previous_summary: bool,
    pub reported_context: Option<ModelContext>,
}

pub(super) struct Budget {
    pub(super) input: u64,
    pub(super) output: usize,
    pub(super) explicit_cap: bool,
    compaction: CompactionSettings,
}

impl ContextSettings {
    pub(super) fn budget(self, connection: &Connection, model: &str) -> anyhow::Result<Budget> {
        for (value, min, max, key) in [
            (self.context_tokens, 4096, 2_000_000, "contextTokens"),
            (self.reserve_tokens, 256, 65_536, "reserveTokens"),
            (self.keep_recent_tokens, 256, 200_000, "keepRecentTokens"),
        ] {
            anyhow::ensure!(
                value.is_none_or(|value| (min..=max).contains(&value)),
                "Harness {key} must be between {min} and {max}."
            );
        }

        let local = connection.provider == ProviderKind::Fritz;
        let positive = |value: Option<u32>| value.filter(|&value| value > 0).map(u64::from);
        let bundled = model_context::bundled(connection, model);
        let limits = self.reported_context.unwrap_or(bundled);
        let route = positive(limits.effective_window_tokens);
        let advertised = positive(limits.window_tokens);
        // An unloaded Ollama model may use a server-wide context setting.
        // Keep the published architecture cap in the catalog and use a
        // conservative budget until the selected server reports a runtime cap.
        let route = route.or_else(|| {
            (connection.provider == ProviderKind::Ollama && self.context_tokens.is_none())
                .then_some(4096)
        });
        let shared_window = route.into_iter().chain(advertised).min();
        let max_input = positive(limits.input_tokens);
        let max_output = positive(limits.output_tokens);
        let automatic = shared_window
            .or_else(|| max_input.map(|input| input.saturating_add(max_output.unwrap_or(8192))));
        let known_window = if local {
            positive(bundled.effective_window_tokens)
        } else {
            automatic
        };
        let window = self
            .context_tokens
            .or(known_window)
            .unwrap_or(32_768)
            .min(known_window.unwrap_or(u64::MAX));
        let mut compaction = CompactionSettings::default();
        compaction.enabled = self.automatic_compaction.unwrap_or(compaction.enabled);
        compaction.reserve_tokens = self
            .reserve_tokens
            .unwrap_or(
                compaction
                    .reserve_tokens
                    .min(if local { 2048 } else { window / 4 }),
            )
            .min(window / 2);
        let input = (window - compaction.reserve_tokens).min(max_input.unwrap_or(u64::MAX));
        compaction.keep_recent_tokens = self
            .keep_recent_tokens
            .unwrap_or(compaction.keep_recent_tokens.min(input / 2))
            .min(input.saturating_sub(1024).max(1));
        let output = compaction
            .reserve_tokens
            .min(if local { 2048 } else { 8192 })
            .min(max_output.unwrap_or(u64::MAX))
            .max(1);
        Ok(Budget {
            input,
            output: output as usize,
            explicit_cap: self.context_tokens.is_some(),
            compaction,
        })
    }
}

fn user_prompt(message: &Message) -> bool {
    matches!(message, Message::User { content } if content.iter().any(|part| matches!(part, UserContent::Text(_))))
}

impl Budget {
    pub(super) fn cut(
        &self,
        history: &[Message],
        (system, tools): (&str, &str),
        overflow: bool,
        prior_summary: bool,
        anchor: Option<(u64, usize)>,
    ) -> Option<usize> {
        let tokens = request_tokens((Some(system), Some(tools)), history, anchor);
        let window = self.input + self.compaction.reserve_tokens;
        if !self.compaction.enabled
            || (!overflow && !self.compaction.should_compact(tokens, window))
        {
            return None;
        }
        let last = history.iter().rposition(user_prompt)?;
        let proposed = if overflow {
            last
        } else {
            let messages: Vec<_> = history.iter().cloned().map(Arc::new).collect();
            find_cut_point(
                &messages,
                (0, history.len()),
                self.compaction.keep_recent_tokens,
                false,
            )
            .min(last)
        };
        // Keep complete conversational turns and always keep the current user
        // prompt and its native tool exchanges. A single oversized older turn
        // may require advancing past the suggested retention target.
        let mut suffix = request_tokens((Some(system), Some(tools)), &history[proposed..], None);
        let mut boundary = None;
        for (index, message) in history.iter().enumerate().skip(1).take(last) {
            if index > proposed {
                suffix = suffix.saturating_sub(request_tokens(
                    (None, None),
                    &history[index - 1..index],
                    None,
                ));
            }
            if index > usize::from(prior_summary) && user_prompt(message) {
                boundary = Some(index);
                if index >= proposed && suffix <= self.input.saturating_sub(1024) {
                    break;
                }
            }
        }
        boundary
    }
}

pub(super) fn used_tokens(
    usage: &serde_json::Map<String, serde_json::Value>,
    provider: ProviderKind,
) -> Option<u64> {
    let count = |key| usage.get(key).and_then(serde_json::Value::as_u64);
    let (input, output) = match provider {
        ProviderKind::Gemini => (
            count("promptTokenCount")?,
            count("candidatesTokenCount")?.saturating_add(count("thoughtsTokenCount").unwrap_or(0)),
        ),
        ProviderKind::OpenaiCompatible | ProviderKind::Openrouter => {
            (count("prompt_tokens")?, count("completion_tokens")?)
        }
        ProviderKind::Anthropic => (
            count("input_tokens")?
                .saturating_add(count("cache_creation_input_tokens").unwrap_or(0))
                .saturating_add(count("cache_read_input_tokens").unwrap_or(0)),
            count("output_tokens")?,
        ),
        _ => (count("input_tokens")?, count("output_tokens")?),
    };
    (input > 0).then_some(input.saturating_add(output))
}
