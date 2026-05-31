// ── Craft extractor ───────────────────────────────────────────────────────────
//
// Status: SKELETON — Craft's REST API exists at https://api.craft.do/v1/ but has
// no public documentation as of 2026-05. These stubs establish the module structure
// and will be filled in once the API contract is confirmed (reverse-engineering or
// official docs from Craft).
//
// Known facts:
//   - Base URL: https://api.craft.do/v1/
//   - Auth: bearer token (OAuth2, exact flow TBD)
//   - Endpoints (unconfirmed): /v1/spaces, /v1/documents, /v1/blocks/{id}/children
//   - Block structure: hierarchical, rich text inline styles
//
// Pipeline (planned):
//   → GET /v1/spaces             (list available spaces)
//   → GET /v1/spaces/{id}/documents (list documents)
//   → GET /v1/documents/{id}     (document + blocks, possibly paginated)
//   → map → persist via DocumentRepository

pub mod client;
pub mod schema;
pub mod mapper;

use crate::application::database_repository::DatabaseRepository;
use crate::application::repository::DocumentRepository;
use crate::extractors::traits::Extractor;
use crate::extractors::{ExtractorError, ImportResult};

// ── Config ────────────────────────────────────────────────────────────────────

/// Input required to run a Craft import.
///
/// `token` is a bearer token obtained via the Craft OAuth2 flow (handled by Swift).
/// `space_id` is the ID of the Craft space to import; leave empty to import all spaces.
pub struct CraftConfig {
    /// Bearer token for the Craft API.
    pub token: String,
    /// ID of the Craft space to import, or empty string to import all accessible spaces.
    pub space_id: String,
}

// ── Extractor ─────────────────────────────────────────────────────────────────

pub struct CraftExtractor;

impl CraftExtractor {
    pub fn new() -> Self {
        Self
    }
}

impl Default for CraftExtractor {
    fn default() -> Self {
        Self::new()
    }
}

impl Extractor for CraftExtractor {
    type Config = CraftConfig;

    fn app_name(&self) -> &'static str {
        "Craft"
    }

    fn run(
        &self,
        _config: CraftConfig,
        _docs: &(dyn DocumentRepository + Send + Sync),
        _dbs: &(dyn DatabaseRepository + Send + Sync),
    ) -> impl std::future::Future<Output = Result<ImportResult, ExtractorError>> + Send {
        async {
            // TODO: implement once Craft API documentation is available.
            // Suggested order:
            //   1. CraftClient::new(&config.token)?
            //   2. client.list_spaces() (or use config.space_id directly)
            //   3. For each space: client.list_documents(space_id)
            //   4. For each document: client.get_document(doc_id) → blocks
            //   5. map_block() for each block (recursive children)
            //   6. use_cases::create_document + bulk add_block + save
            Err(ExtractorError::Parse(
                "Craft extractor not yet implemented — API documentation pending".to_string(),
            ))
        }
    }
}
