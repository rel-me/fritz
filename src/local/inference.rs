//! Offline chat inference adapted from REL, with cancellable token streaming.
use anyhow::{Result, anyhow};
use llama_cpp_2::{
    context::params::LlamaContextParams,
    llama_backend::LlamaBackend,
    llama_batch::LlamaBatch,
    model::{AddBos, LlamaModel, params::LlamaModelParams},
    sampling::LlamaSampler,
};
use std::{
    num::NonZeroU32,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, Ordering},
    },
    time::Instant,
};
use std::{path::PathBuf, time::Duration};

const BATCH: usize = 256;

pub(crate) struct Generation {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub truncated: bool,
}

fn error(message: &str) -> anyhow::Error {
    anyhow!("Fritz local model: {message}")
}

// The model is shared across turns in the same agent. Its context is fresh per
// request so data cannot leak between calls. Backend outlives every model.
static BACKEND: OnceLock<Result<LlamaBackend, String>> = OnceLock::new();
#[derive(Clone)]
pub(crate) struct Engine {
    pub model_id: String,
    path: PathBuf,
    model: Arc<Mutex<Option<LlamaModel>>>,
}

struct Cancellation(Arc<AtomicBool>);
impl Drop for Cancellation {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Relaxed);
    }
}

impl Engine {
    pub async fn unload(self) {
        // Rust statics are not dropped at exit. Release weights before Metal's
        // native global destructors, waiting for any cancelled worker to finish.
        let _ = tokio::task::spawn_blocking(move || {
            let mut model = self
                .model
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            *model = None;
        })
        .await;
    }

    pub async fn installed(model_id: &str) -> Result<Self, anyhow::Error> {
        let path = super::models::installed_path(model_id).await?;
        Ok(Self {
            model_id: model_id.into(),
            path,
            model: Arc::new(Mutex::new(None)),
        })
    }

    pub async fn generate(
        &self,
        mut prompt: String,
        grammar: Option<&'static str>,
        context_size: usize,
        output_limit: usize,
        timeout: Duration,
        output: tokio::sync::mpsc::UnboundedSender<String>,
    ) -> Result<Generation, anyhow::Error> {
        let path = self.path.clone();
        let model_id = self.model_id.clone();
        if super::models::manifest(&model_id)?.disable_thinking {
            // All catalog entries use ChatML. Close the thinking block explicitly,
            // matching their published enable_thinking=false generation prefix.
            prompt.push_str("<think>\n\n</think>\n\n");
        }
        let model = self.model.clone();
        let cancelled = Arc::new(AtomicBool::new(false));
        let _guard = Cancellation(cancelled.clone());
        let started = Instant::now();
        let work = tokio::task::spawn_blocking(move || {
            let active = || !cancelled.load(Ordering::Relaxed) && started.elapsed() < timeout;
            let check = || {
                if active() {
                    Ok(())
                } else {
                    Err(error("generation cancelled or timed out"))
                }
            };
            check()?;
            let backend = BACKEND
                .get_or_init(|| {
                    let mut backend = LlamaBackend::init().map_err(|e| e.to_string())?;
                    backend.void_logs();
                    Ok(backend)
                })
                .as_ref()
                .map_err(|_| error("cannot initialize inference runtime"))?;
            let mut cached = model
                .lock()
                .map_err(|_| error("model worker unavailable"))?;
            check()?;
            let cold = cached.is_none();
            if cold {
                let loading_cancelled = cancelled.clone();
                let params = LlamaModelParams::default()
                    .with_n_gpu_layers(1000)
                    .with_progress_callback(move |_| {
                        !loading_cancelled.load(Ordering::Relaxed) && started.elapsed() < timeout
                    });
                *cached = Some(
                    LlamaModel::load_from_file(backend, path, &params)
                        .map_err(|_| error("cannot load pinned weights"))?,
                );
            }
            check()?;
            let model = cached.as_ref().unwrap();
            let tokens = model
                .str_to_token(&prompt, AddBos::Never)
                .map_err(|_| error("cannot tokenize text"))?;
            if tokens.is_empty() || tokens.len() + output_limit > context_size {
                return Err(error("request exceeds the local model context limit"));
            }
            let params = LlamaContextParams::default()
                .with_n_ctx(NonZeroU32::new(context_size as u32))
                .with_n_batch(BATCH as u32)
                .with_n_ubatch(BATCH as u32)
                .with_n_threads(4)
                .with_n_threads_batch(4);
            let mut ctx = model
                .new_context(backend, params)
                .map_err(|_| error("cannot allocate inference context"))?;
            let mut batch = LlamaBatch::new(BATCH, 1);
            for (chunk_index, chunk) in tokens.chunks(BATCH).enumerate() {
                check()?;
                batch.clear();
                for (index, token) in chunk.iter().enumerate() {
                    let position = chunk_index * BATCH + index;
                    batch
                        .add(*token, position as i32, &[0], position + 1 == tokens.len())
                        .map_err(|_| error("cannot prepare chat context"))?;
                }
                ctx.decode(&mut batch)
                    .map_err(|_| error("context evaluation failed"))?;
            }
            let mut samplers = Vec::new();
            if let Some(grammar) = grammar {
                samplers.push(
                    LlamaSampler::grammar(model, grammar, "root")
                        .map_err(|_| error("cannot initialize output grammar"))?,
                );
            }
            samplers.push(LlamaSampler::greedy());
            let mut sampler = LlamaSampler::chain_simple(samplers);
            let mut bytes = Vec::new();
            for index in 0..output_limit {
                check()?;
                let token = sampler.sample(&ctx, batch.n_tokens() - 1);
                // sample() already accepts the token into the grammar.
                if model.is_eog_token(token) {
                    flush_text(&mut bytes, &output)?;
                    if !bytes.is_empty() {
                        return Err(error("invalid UTF-8 output"));
                    }
                    return Ok(Generation {
                        input_tokens: tokens.len() as u64,
                        output_tokens: (index + 1) as u64,
                        truncated: false,
                    });
                }
                bytes.extend(
                    model
                        .token_to_piece_bytes(token, 4096, false, None)
                        .map_err(|_| error("cannot decode chat text"))?,
                );
                flush_text(&mut bytes, &output)?;
                batch.clear();
                batch
                    .add(token, (tokens.len() + index) as i32, &[0], true)
                    .map_err(|_| error("cannot prepare output token"))?;
                ctx.decode(&mut batch)
                    .map_err(|_| error("output evaluation failed"))?;
            }
            if !bytes.is_empty() {
                return Err(error("invalid UTF-8 output"));
            }
            Ok(Generation {
                input_tokens: tokens.len() as u64,
                output_tokens: output_limit as u64,
                truncated: true,
            })
        });
        tokio::time::timeout(timeout, work)
            .await
            .map_err(|_| error("generation deadline exceeded"))?
            .map_err(|_| error("inference worker failed"))?
    }
}

// A token can end mid-scalar; emit only complete UTF-8 while retaining its tail.
fn flush_text(
    bytes: &mut Vec<u8>,
    output: &tokio::sync::mpsc::UnboundedSender<String>,
) -> Result<()> {
    let length = match std::str::from_utf8(bytes) {
        Ok(text) => text.len(),
        Err(problem) if problem.error_len().is_none() => problem.valid_up_to(),
        Err(_) => return Err(error("invalid UTF-8 output")),
    };
    if length > 0 {
        let text = std::str::from_utf8(&bytes[..length]).unwrap().to_owned();
        output
            .send(text)
            .map_err(|_| error("generation cancelled"))?;
        bytes.drain(..length);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dropping_request_signals_blocking_worker() {
        let signal = Arc::new(AtomicBool::new(false));
        let guard = Cancellation(signal.clone());
        assert!(!signal.load(Ordering::Relaxed));
        drop(guard);
        assert!(signal.load(Ordering::Relaxed));
    }
    #[test]
    fn token_stream_preserves_split_unicode_and_rejects_closed_consumers() {
        let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
        let mut pending = Vec::new();
        for byte in "Hello café 🦀".as_bytes() {
            pending.push(*byte);
            flush_text(&mut pending, &sender).unwrap();
        }
        assert!(pending.is_empty());
        let mut text = String::new();
        while let Ok(chunk) = receiver.try_recv() {
            text.push_str(&chunk);
        }
        assert_eq!(text, "Hello café 🦀");
        drop(receiver);
        assert!(flush_text(&mut b"late".to_vec(), &sender).is_err());
    }
}
