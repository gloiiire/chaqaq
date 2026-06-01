// ── Extractor layer ───────────────────────────────────────────────────────────
//
// One extractor per source application. Each extractor:
//   1. Owns an HTTP client (or file reader) specific to its source API.
//   2. Maps the source's data model to Pinkha domain types.
//   3. Persists via DocumentRepository + DatabaseRepository — no direct SQLite.
//
// The trait lives in `traits.rs`. Concrete implementations live in submodules.
// OAuth2 token exchange (browser flow, Keychain) stays in Swift; Rust only
// receives the final bearer token.

pub mod traits;
pub mod notion;
pub mod bear;
pub mod craft;
pub mod craft_textbundle;

use crate::application::error::PinkhaError;
use uuid::Uuid;

// ── Error ─────────────────────────────────────────────────────────────────────

/// Errors that can occur during an extraction pipeline.
#[derive(Debug)]
pub enum ExtractorError {
    /// The source API returned a non-2xx HTTP status.
    Http { status: u16, message: String },
    /// Authentication or authorisation failure (expired token, wrong scope, etc.).
    Auth(String),
    /// The API response could not be parsed (unexpected schema, missing field).
    Parse(String),
    /// A Pinkha storage operation failed while persisting the imported data.
    Storage(PinkhaError),
}

impl std::fmt::Display for ExtractorError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Http { status, message } => write!(f, "HTTP {status}: {message}"),
            Self::Auth(msg) => write!(f, "auth error: {msg}"),
            Self::Parse(msg) => write!(f, "parse error: {msg}"),
            Self::Storage(e) => write!(f, "storage error: {e}"),
        }
    }
}

impl std::error::Error for ExtractorError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Storage(e) => Some(e),
            _ => None,
        }
    }
}

impl From<PinkhaError> for ExtractorError {
    fn from(e: PinkhaError) -> Self {
        Self::Storage(e)
    }
}

impl From<serde_json::Error> for ExtractorError {
    fn from(e: serde_json::Error) -> Self {
        Self::Parse(e.to_string())
    }
}

impl From<reqwest::Error> for ExtractorError {
    fn from(e: reqwest::Error) -> Self {
        if let Some(status) = e.status() {
            Self::Http {
                status: status.as_u16(),
                message: e.to_string(),
            }
        } else {
            Self::Parse(e.to_string())
        }
    }
}

// ── Result ────────────────────────────────────────────────────────────────────

/// Summary of a completed import pipeline.
#[derive(Debug, Clone)]
pub struct ImportResult {
    /// Human-readable name of the source app (e.g. "Notion", "Bear").
    pub app: &'static str,
    /// ID of the Pinkha database created during this import, if any.
    pub database_id: Option<Uuid>,
    /// Number of Pinkha documents created.
    pub documents: usize,
    /// Number of database entries created.
    pub entries: usize,
    /// Number of blocks added across all documents.
    pub blocks: usize,
    /// Number of source items dropped because they had no Pinkha equivalent.
    pub skipped: usize,
}
