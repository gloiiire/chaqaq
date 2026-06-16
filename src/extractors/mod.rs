// ── Extractor layer ───────────────────────────────────────────────────────────
//
// One extractor per source application. Each extractor:
//   1. Owns an HTTP client (or file reader) specific to its source API.
//   2. Maps the source's data model to Pinkha domain types.
//   3. Persists via LeafRepository + BookRepository — no direct SQLite.
//
// The trait lives in `traits.rs`. Concrete implementations live in submodules.
// OAuth2 token exchange (browser flow, Keychain) stays in Swift; Rust only
// receives the final bearer token.

pub mod bear;
pub mod craft;
pub mod craft_combined;
pub mod craft_textbundle;
pub mod notion;
pub mod traits;

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
    /// The user cancelled the import; everything created so far was removed.
    Cancelled,
}

impl std::fmt::Display for ExtractorError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Http { status, message } => write!(f, "HTTP {status}: {message}"),
            Self::Auth(msg) => write!(f, "auth error: {msg}"),
            Self::Parse(msg) => write!(f, "parse error: {msg}"),
            Self::Storage(e) => write!(f, "storage error: {e}"),
            Self::Cancelled => write!(f, "import cancelled"),
        }
    }
}

/// Process-wide cancellation flag for the currently running import.
///
/// Imports run one at a time (the UI serialises them), so a single flag is
/// enough: the FFI sets it from the UI thread, the import loop polls it
/// between pages, rolls back what it created and returns
/// [`ExtractorError::Cancelled`]. The flag is reset at the start of every
/// import so a stale request can never kill the next run.
pub mod cancel {
    use std::sync::atomic::{AtomicBool, Ordering};

    static REQUESTED: AtomicBool = AtomicBool::new(false);

    /// Asks the in-flight import to stop and roll back.
    pub fn request() {
        REQUESTED.store(true, Ordering::SeqCst);
    }

    /// Clears any pending request — called when an import starts.
    pub fn reset() {
        REQUESTED.store(false, Ordering::SeqCst);
    }

    /// Polled by import loops between pages.
    pub fn requested() -> bool {
        REQUESTED.load(Ordering::SeqCst)
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn request_then_reset_round_trip() {
            reset();
            assert!(!requested());
            request();
            assert!(requested());
            reset();
            assert!(!requested());
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
    /// ID of the Pinkha book created during this import, if any.
    pub book_id: Option<Uuid>,
    /// Number of Pinkha leaves created.
    pub leaves: usize,
    /// Number of book entries created.
    pub entries: usize,
    /// Number of blocks added across all leaves.
    pub blocks: usize,
    /// Number of source items dropped because they had no Pinkha equivalent.
    pub skipped: usize,
}
