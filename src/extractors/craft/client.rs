// ── Craft HTTP client (stub) ──────────────────────────────────────────────────
//
// Placeholder — will be implemented once Craft API documentation is confirmed.
// The planned interface mirrors the Notion client.

use crate::extractors::ExtractorError;

pub struct CraftClient {
    _token: String,
}

impl CraftClient {
    pub fn new(token: &str) -> Result<Self, ExtractorError> {
        if token.is_empty() {
            return Err(ExtractorError::Auth("Craft token is empty".to_string()));
        }
        Ok(Self { _token: token.to_string() })
    }
}
