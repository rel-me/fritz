//! Shared infrastructure for Fritz and other native macOS applications.
//!
//! Use [`models_service::ModelsService`] with an injected [`config::ProviderStorage`],
//! [`config::CredentialStore`] and
//! [`local::models::ModelStore`] for host-owned storage and credential references. Module-level
//! convenience functions retain Fritz's default paths and Keychain namespace.
//! [`harness::run`] accepts explicit connection/credential input; its folder
//! actions execute with the current user's permissions, not an OS sandbox.

pub mod config;
pub mod decision;
pub mod decision_client;
pub mod harness;
pub mod harness_client;
pub mod local;
#[cfg(target_os = "macos")]
pub mod models_service;
pub mod provider;
pub mod tools;

pub use fritz_state as state;

/// Lightweight execution interfaces; also available as a standalone dependency.
pub use fritz_harness as harness_core;
