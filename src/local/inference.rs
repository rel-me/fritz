//! Offline inference for verified catalog weights through mistral.rs.
use anyhow::{Result, anyhow};
use mistralrs::{
    Constraint, GgufModelBuilder, Model, NormalRequest, Request, RequestLike, RequestMessage,
    Response, SamplingParams, TextMessageRole, TextMessages, TokenSource,
};
use std::{path::PathBuf, sync::Arc, time::Duration};
use tokio::sync::OnceCell;

// Upper bound for any request; `GenerationOptions::context_size` narrows it.
const MAX_CONTEXT: usize = 32768;

pub struct Generation {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub truncated: bool,
}

/// Text sent to the model: chat turns rendered by the weights' own template, or raw text.
pub enum Prompt {
    Chat(Vec<(String, String)>),
    Raw(String),
}

pub struct GenerationOptions {
    pub json: bool,
    pub context_size: usize,
    pub output_limit: usize,
    pub timeout: Duration,
}

fn error(message: &str) -> anyhow::Error {
    anyhow!("Fritz local model: {message}")
}

// Weights belong to the current harness process. Requests share weights, never
// conversation state: the prefix cache is disabled and one sequence runs at a time.
#[derive(Clone)]
pub struct Engine {
    pub(crate) model_id: String,
    path: PathBuf,
    model: Arc<OnceCell<Model>>,
}

impl Engine {
    /// Catalog identifier of the verified weights owned by this engine.
    pub fn model_id(&self) -> &str {
        &self.model_id
    }

    /// Releases the weights once no request holds this engine.
    pub async fn unload(self) {
        drop(self);
    }

    pub async fn installed(model_id: &str) -> Result<Self, anyhow::Error> {
        Self::installed_in(
            &super::models::ModelStore::new(crate::config::data_dir()),
            model_id,
        )
        .await
    }

    /// Verifies installed weights in the caller's store before constructing a lazy engine.
    pub async fn installed_in(store: &super::models::ModelStore, model_id: &str) -> Result<Self> {
        let path = store.installed_path(model_id).await?;
        Ok(Self {
            model_id: model_id.into(),
            path,
            model: Arc::new(OnceCell::new()),
        })
    }

    async fn model(&self) -> Result<&Model> {
        self.model
            .get_or_try_init(|| async {
                let directory = self
                    .path
                    .parent()
                    .ok_or_else(|| error("invalid model path"))?;
                let file = self
                    .path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .ok_or_else(|| error("invalid model path"))?;
                // A local directory never queries Hugging Face; the tokenizer and
                // chat template come from the pinned GGUF metadata.
                GgufModelBuilder::new(directory.to_string_lossy(), vec![file])
                    .with_token_source(TokenSource::None)
                    .with_max_model_len(MAX_CONTEXT)
                    .with_max_num_seqs(1)
                    .with_prefix_cache_n(None)
                    .build()
                    .await
                    .map_err(|problem| error(&format!("cannot load pinned weights: {problem}")))
            })
            .await
    }

    pub async fn generate(
        &self,
        prompt: Prompt,
        options: GenerationOptions,
        output: tokio::sync::mpsc::UnboundedSender<String>,
    ) -> Result<Generation> {
        let timeout = options.timeout;
        tokio::time::timeout(timeout, self.run(prompt, options, output))
            .await
            .map_err(|_| error("generation deadline exceeded"))?
    }

    async fn run(
        &self,
        prompt: Prompt,
        options: GenerationOptions,
        output: tokio::sync::mpsc::UnboundedSender<String>,
    ) -> Result<Generation> {
        let model = self.model().await?;
        // Catalog entries with thinking disabled use the template's enable_thinking=false prefix.
        let thinking = super::models::manifest(&self.model_id)?
            .disable_thinking
            .then_some(false);
        let (message, input_tokens) = match prompt {
            Prompt::Chat(turns) => {
                let mut messages = TextMessages::new();
                for (role, content) in turns {
                    let role = match role.as_str() {
                        "system" => TextMessageRole::System,
                        "user" => TextMessageRole::User,
                        "assistant" => TextMessageRole::Assistant,
                        _ => return Err(error("unsupported message role")),
                    };
                    messages = messages.add_message(role, content);
                }
                if let Some(enabled) = thinking {
                    messages = messages.enable_thinking(enabled);
                }
                let tokens = model
                    .tokenize(
                        either::Either::Left(messages.clone()),
                        None,
                        false,
                        true,
                        thinking,
                    )
                    .await
                    .map_err(|_| error("cannot tokenize text"))?;
                (messages.take_messages(), tokens.len())
            }
            Prompt::Raw(text) => {
                let tokens = model
                    .tokenize(
                        either::Either::Right(text.clone()),
                        None,
                        false,
                        false,
                        None,
                    )
                    .await
                    .map_err(|_| error("cannot tokenize text"))?;
                let message = RequestMessage::Completion {
                    text,
                    echo_prompt: false,
                    best_of: None,
                };
                (message, tokens.len())
            }
        };
        if input_tokens == 0
            || input_tokens + options.output_limit > options.context_size.min(MAX_CONTEXT)
        {
            return Err(error("request exceeds the local model context limit"));
        }
        let mut sampling = SamplingParams::deterministic();
        sampling.max_len = Some(options.output_limit);
        let (sender, mut receiver) = tokio::sync::mpsc::channel(64);
        let mut request = NormalRequest::new_simple(message, sampling, sender, 0, None, None);
        request.is_streaming = true;
        if options.json {
            request.constraint = Constraint::JsonSchema(serde_json::json!({}));
        }
        model
            .inner()
            .get_sender(None)
            .map_err(|_| error("model worker unavailable"))?
            .send(Request::Normal(Box::new(request)))
            .await
            .map_err(|_| error("model worker unavailable"))?;
        // Dropping the receiver (cancellation or deadline) stops the sequence.
        let mut output_tokens = 0;
        let mut reported = None;
        let mut finish = None;
        while let Some(response) = receiver.recv().await {
            let (text, reason) = match response {
                Response::Chunk(chunk) => {
                    reported = chunk.usage.map(|usage| usage.completion_tokens);
                    let choice = chunk.choices.into_iter().next();
                    choice
                        .map(|choice| (choice.delta.content, choice.finish_reason))
                        .unwrap_or_default()
                }
                Response::CompletionChunk(chunk) => chunk
                    .choices
                    .into_iter()
                    .next()
                    .map(|choice| (Some(choice.text), choice.finish_reason))
                    .unwrap_or_default(),
                Response::Done(done) => {
                    reported = Some(done.usage.completion_tokens);
                    break;
                }
                Response::CompletionDone(done) => {
                    reported = Some(done.usage.completion_tokens);
                    break;
                }
                Response::InternalError(problem) | Response::ValidationError(problem) => {
                    return Err(error(&format!("generation failed: {problem}")));
                }
                Response::ModelError(problem, _) | Response::CompletionModelError(problem, _) => {
                    return Err(error(&format!("generation failed: {problem}")));
                }
                _ => continue,
            };
            if let Some(text) = text.filter(|text| !text.is_empty()) {
                output_tokens += 1;
                output
                    .send(text)
                    .map_err(|_| error("generation cancelled"))?;
            }
            if reason.is_some() {
                finish = reason;
                if reported.is_some() {
                    break;
                }
            }
        }
        let Some(finish) = finish else {
            return Err(error("generation ended unexpectedly"));
        };
        Ok(Generation {
            input_tokens: input_tokens as u64,
            output_tokens: reported.unwrap_or(output_tokens) as u64,
            truncated: finish == "length",
        })
    }
}
