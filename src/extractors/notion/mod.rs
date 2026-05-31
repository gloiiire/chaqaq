// ── Notion extractor ──────────────────────────────────────────────────────────
//
// Pipeline: OAuth2 token (obtained by Swift) + database ID
//   → GET /v1/databases/{id}          (schema: properties + title)
//   → POST /v1/databases/{id}/query   (entries, paginated)
//   → GET /v1/blocks/{page_id}/children (block content, paginated)
//   → map → persist via DocumentRepository + DatabaseRepository
//
// Submodules (to be implemented):
//   client.rs  — reqwest HTTP wrapper, auth headers, rate-limit retry
//   schema.rs  — serde types for every Notion API response shape
//   mapper.rs  — Notion types → Pinkha domain types (BlockContent, PropertyValue, …)

// pub mod client;   // ← uncomment when implementing
// pub mod schema;
// pub mod mapper;

use crate::application::database_repository::DatabaseRepository;
use crate::application::repository::DocumentRepository;
use crate::extractors::{ExtractorError, ImportResult};
use crate::extractors::traits::Extractor;

// ── Config ────────────────────────────────────────────────────────────────────

/// Input required to run a Notion import.
///
/// `token` is a bearer token — either an OAuth2 access token obtained via the
/// public integration flow or a private integration token (`secret_xxx`).
/// Swift handles the OAuth2 browser dance; Rust only receives the final token.
pub struct NotionConfig {
    /// Bearer token for the Notion API.
    pub token: String,
    /// ID (32-char hex) or URL of the Notion database to import.
    pub database_id: String,
}

// ── Extractor ─────────────────────────────────────────────────────────────────

pub struct NotionExtractor;

impl NotionExtractor {
    pub fn new() -> Self {
        Self
    }
}

impl Default for NotionExtractor {
    fn default() -> Self {
        Self::new()
    }
}

impl Extractor for NotionExtractor {
    type Config = NotionConfig;

    fn app_name(&self) -> &'static str {
        "Notion"
    }

    async fn run(
        &self,
        _config: NotionConfig,
        _docs: &(dyn DocumentRepository + Send + Sync),
        _dbs: &(dyn DatabaseRepository + Send + Sync),
    ) -> Result<ImportResult, ExtractorError> {
        // Implementation order:
        //   1. client.rs  — build reqwest client with auth + Notion-Version header
        //   2. schema.rs  — deserialise database schema and page results
        //   3. mapper.rs  — BlockContent, PropertyType, PropertyValue mappings
        //   4. Wire up pagination loops (schema → entries → blocks per page)
        todo!("NotionExtractor — implementation in progress")
    }
}
