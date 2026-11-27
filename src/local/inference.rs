//! In-process inference for Fritz's pinned GGUFs via llama.cpp.
use super::native::Model;
use anyhow::{Context, Result};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::OnceCell;

pub struct Engine {
    pub(crate) model_id: String,
    path: PathBuf,
    context_size: usize,
    minimum_context: usize,
    quantize_kv_cache: bool,
    model: OnceCell<Arc<Model>>,
}

impl Engine {
    pub fn model_id(&self) -> &str {
        &self.model_id
    }

    pub(crate) fn context_size(&self) -> usize {
        self.context_size
    }

    pub async fn installed(model_id: &str) -> Result<Self> {
        Self::installed_with_context(model_id, super::LEGACY_CHAT_CONTEXT_TOKENS as usize).await
    }

    pub(crate) async fn installed_with_context(
        model_id: &str,
        context_size: usize,
    ) -> Result<Self> {
        let mut engine =
            Self::installed_in(&super::models::ModelStore::configured()?, model_id).await?;
        engine.context_size = context_size;
        Ok(engine)
    }

    pub async fn installed_in_with_context(
        store: &super::models::ModelStore,
        model_id: &str,
        context_size: usize,
    ) -> Result<Self> {
        let mut engine = Self::installed_in(store, model_id).await?;
        engine.context_size = context_size;
        Ok(engine)
    }

    pub(crate) async fn for_chat(
        store: &super::models::ModelStore,
        model_id: &str,
        requested: Option<u64>,
        quantize_kv_cache: bool,
    ) -> Result<Self> {
        let pin = super::models::manifest(model_id)?;
        let mut engine = Self::installed_in(store, model_id).await?;
        let maximum = u64::from(pin.limit.context);
        let automatic = pin.limit.automatic_target.unwrap_or(pin.limit.context);
        let target = requested.unwrap_or(u64::from(automatic)).min(maximum);
        engine.context_size = usize::try_from(target)?;
        engine.quantize_kv_cache = quantize_kv_cache;
        engine.minimum_context = if requested.is_some() {
            engine.context_size
        } else {
            engine
                .context_size
                .min(super::LEGACY_CHAT_CONTEXT_TOKENS as usize)
        };
        Ok(engine)
    }

    /// Resolve present model files without loading them or accessing the network.
    pub async fn installed_in(store: &super::models::ModelStore, model_id: &str) -> Result<Self> {
        Ok(Self {
            model_id: model_id.to_owned(),
            path: store.installed_path(model_id).await?,
            context_size: super::LEGACY_CHAT_CONTEXT_TOKENS
                .min(super::models::manifest(model_id)?.limit.context)
                as usize,
            minimum_context: 0,
            quantize_kv_cache: false,
            model: OnceCell::new(),
        })
    }

    pub(crate) async fn model(&self) -> Result<&Arc<Model>> {
        self.model_with_progress(|_| {}).await
    }

    pub(crate) async fn model_with_progress(
        &self,
        progress: impl FnMut(f32),
    ) -> Result<&Arc<Model>> {
        let architecture = &super::models::manifest(&self.model_id)?.architecture;
        let loaded = self
            .model
            .get_or_try_init(|| {
                Model::load_with_context_fit(
                    &self.path,
                    self.context_size,
                    self.minimum_context,
                    Some(architecture),
                    self.quantize_kv_cache,
                    progress,
                )
            })
            .await;
        if self.minimum_context == 0 {
            loaded.context("Could not load the installed GGUF with llama.cpp")
        } else {
            loaded
        }
    }

    pub async fn unload(self) {
        // The model is owned by this harness process. Its streams are dropped
        // before this engine, so releasing it also releases its Metal weights.
        drop(self);
    }
}

#[cfg(test)]
mod tests {
    use super::Engine;
    use crate::local::models;

    #[tokio::test]
    async fn inkling_starts_smaller_on_automatic_and_honors_fixed_context() -> anyhow::Result<()> {
        let directory = tempfile::tempdir()?;
        let store = models::ModelStore::new(directory.path());
        for id in ["inkling-2-mini-iq4_nl", "inkling-2-mini-ud-iq3_xxs"] {
            let pin = models::manifest(id)?;
            std::fs::File::create(directory.path().join(&pin.file))?;

            let automatic = Engine::for_chat(&store, id, None, true).await?;
            assert_eq!(automatic.context_size(), 16_384);
            let fixed = Engine::for_chat(&store, id, Some(32_768), true).await?;
            assert_eq!(fixed.context_size(), 32_768);
        }
        Ok(())
    }
}
