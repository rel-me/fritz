//! Shared infrastructure for Fritz and other native macOS applications.
//!
//! Use [`config::RegistryStore`], [`config::CredentialStore`] and
//! [`local::models::ModelStore`] to isolate a host's storage. Module-level
//! convenience functions retain Fritz's default paths and Keychain namespace.
//! [`harness::run`] accepts explicit connection/credential input; its coding
//! tools execute with the current user's permissions, not an OS sandbox.

pub mod config;
pub mod harness;
pub mod harness_client;
pub mod local;
pub mod provider;
pub mod tools;
