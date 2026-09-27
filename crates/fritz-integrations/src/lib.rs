//! Integration services with explicit host-owned identity and command policy.
#[cfg(feature = "remote-access")]
pub mod remote;
#[cfg(all(feature = "whatsapp", target_os = "macos"))]
pub mod whatsapp;

/// Preserve input, service, I/O and JSON failures so each host can retain its RPC error contract.
#[derive(Debug)]
pub enum Error {
    Usage(String),
    Capture(String),
    Io(std::io::Error),
    Json(serde_json::Error),
}
impl Error {
    pub fn usage(message: impl Into<String>) -> Self {
        Self::Usage(message.into())
    }
    pub fn capture(message: impl Into<String>) -> Self {
        Self::Capture(message.into())
    }
    pub fn render_for_stderr(&self) -> String {
        self.to_string()
    }
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Usage(message) | Self::Capture(message) => f.write_str(message),
            Self::Io(error) => error.fmt(f),
            Self::Json(error) => error.fmt(f),
        }
    }
}
impl std::error::Error for Error {}
impl From<std::io::Error> for Error {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}
impl From<serde_json::Error> for Error {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

pub struct Request {
    pub method: String,
    pub path: String,
    pub body: Vec<u8>,
}
