//! In-process inference for Fritz's pinned GGUFs via mistral.rs.
use anyhow::{Context, Result};
use mistralrs::{GgufModelBuilder, Model, TokenSource};
use std::path::PathBuf;
use tokio::sync::OnceCell;

pub struct Engine {
    pub(crate) model_id: String,
    path: PathBuf,
    context_size: usize,
    model: OnceCell<Model>,
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
        let mut engine = Self::installed_in(
            &super::models::ModelStore::new(crate::config::data_dir()),
            model_id,
        )
        .await?;
        engine.context_size = context_size;
        Ok(engine)
    }

    /// Verify installed weights without loading them or accessing the network.
    pub async fn installed_in(store: &super::models::ModelStore, model_id: &str) -> Result<Self> {
        Ok(Self {
            model_id: model_id.to_owned(),
            path: store.installed_path(model_id).await?,
            context_size: 8192,
            model: OnceCell::new(),
        })
    }

    pub(crate) async fn model(&self) -> Result<&Model> {
        self.model
            .get_or_try_init(|| async {
                let directory = self.path.parent().context("Missing model directory")?;
                let filename = self
                    .path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .context("Invalid model filename")?;
                // The installed path has already been verified against Fritz's pinned
                // size and digest. Passing its local directory avoids Hub downloads.
                GgufModelBuilder::new(directory.to_string_lossy(), vec![filename])
                    .with_token_source(TokenSource::None)
                    .with_max_model_len(self.context_size)
                    .with_max_num_seqs(1)
                    .with_prefix_cache_n(None)
                    .build()
                    .await
                    .context("Could not load the installed GGUF with mistral.rs")
            })
            .await
    }

    pub async fn unload(self) {
        // The model is owned by this harness process. Its streams are dropped
        // before this engine, so releasing it also releases its Metal weights.
        drop(self);
    }
}
