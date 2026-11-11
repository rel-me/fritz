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
        Self::installed_with_context(model_id, 8192).await
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

    /// Resolve present model files without loading them or accessing the network.
    pub async fn installed_in(store: &super::models::ModelStore, model_id: &str) -> Result<Self> {
        Ok(Self {
            model_id: model_id.to_owned(),
            path: store.installed_path(model_id).await?,
            context_size: 8192,
            model: OnceCell::new(),
        })
    }

    pub(crate) async fn model(&self) -> Result<&Arc<Model>> {
        self.model
            .get_or_try_init(|| Model::load(&self.path, self.context_size, true))
            .await
            .context("Could not load the installed GGUF with llama.cpp")
    }

    pub async fn unload(self) {
        // The model is owned by this harness process. Its streams are dropped
        // before this engine, so releasing it also releases its Metal weights.
        drop(self);
    }
}
