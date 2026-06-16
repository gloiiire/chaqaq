//! Input validation helpers applied at the FFI boundary.

use serde::de::DeserializeOwned;
use uuid::Uuid;

use super::PinkhaError;
use crate::domain::leaf::Block;

/// Maximum size of JSON payloads accepted at the FFI boundary (5 MB).
///
/// Guards against oversized requests that would saturate memory.
pub(crate) const MAX_JSON_BYTES: usize = 5 * 1024 * 1024;

/// Maximum size of a string input (title, search query).
pub(crate) const MAX_STRING_BYTES: usize = 64 * 1024;

/// Parses a UUID string, returning an [`InvalidOperation`] error on failure.
pub(crate) fn parse_uuid(s: &str) -> Result<Uuid, PinkhaError> {
    Uuid::parse_str(s).map_err(|_| PinkhaError::InvalidOperation {
        detail: format!("invalid UUID: {s}"),
    })
}

/// Parses a list of UUID strings, returning on the first failure.
pub(crate) fn parse_uuids(ids: Vec<String>) -> Result<Vec<Uuid>, PinkhaError> {
    ids.iter().map(|s| parse_uuid(s)).collect()
}

/// Rejects strings that exceed [`MAX_STRING_BYTES`] at the FFI boundary.
pub(crate) fn validate_string(s: &str, field: &str) -> Result<(), PinkhaError> {
    if s.len() > MAX_STRING_BYTES {
        return Err(PinkhaError::InvalidOperation {
            detail: format!(
                "{field} too large: {} bytes (max {MAX_STRING_BYTES})",
                s.len()
            ),
        });
    }
    Ok(())
}

/// Deserializes a JSON string, enforcing the [`MAX_JSON_BYTES`] size limit.
pub(crate) fn parse_json<T: DeserializeOwned>(json: &str) -> Result<T, PinkhaError> {
    if json.len() > MAX_JSON_BYTES {
        return Err(PinkhaError::InvalidOperation {
            detail: format!(
                "JSON payload too large: {} bytes (max {MAX_JSON_BYTES})",
                json.len()
            ),
        });
    }
    serde_json::from_str(json).map_err(|e| PinkhaError::InvalidOperation {
        detail: e.to_string(),
    })
}

/// Serializes a value to JSON, mapping errors to [`Storage`].
pub(crate) fn to_json<T: serde::Serialize>(value: &T) -> Result<String, PinkhaError> {
    serde_json::to_string(value).map_err(|e| PinkhaError::Storage {
        detail: e.to_string(),
    })
}

/// Extracts the UUID string from a [`Block`].
pub(crate) fn get_block_id(block: Block) -> String {
    block.id.to_string()
}
