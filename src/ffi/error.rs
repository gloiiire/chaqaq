//! FFI error type exposed to Swift across the UniFFI boundary.

use crate::application::error::PinkhaError as CoreError;

// ── FFI error ─────────────────────────────────────────────────────────────────

/// Error type exposed to Swift across the FFI boundary.
///
/// Maps the internal [`CoreError`] variants to three coarse categories that
/// are easy to handle in Swift: a resource was not found, the caller sent
/// invalid input, or a storage-layer problem occurred.
#[derive(Debug)]
pub enum PinkhaError {
    /// A resource identified by `id` could not be found.
    NotFound { id: String },
    /// The operation was rejected because of invalid input.
    InvalidOperation { detail: String },
    /// A storage-layer error occurred (I/O, JSON serialization, SQLite).
    Storage { detail: String },
}

impl std::fmt::Display for PinkhaError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotFound { id } => write!(f, "not found: {id}"),
            Self::InvalidOperation { detail } => write!(f, "invalid operation: {detail}"),
            Self::Storage { detail } => write!(f, "storage: {detail}"),
        }
    }
}

impl std::error::Error for PinkhaError {}

impl From<CoreError> for PinkhaError {
    fn from(e: CoreError) -> Self {
        match e {
            CoreError::NotFound(id) => Self::NotFound { id: id.to_string() },
            CoreError::InvalidOperation(msg) => Self::InvalidOperation { detail: msg },
            CoreError::Io(e) => Self::Storage {
                detail: e.to_string(),
            },
            CoreError::Json(e) => Self::Storage {
                detail: e.to_string(),
            },
            CoreError::Db(msg) => Self::Storage { detail: msg },
        }
    }
}
