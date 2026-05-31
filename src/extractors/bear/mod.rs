// ── Bear extractor ────────────────────────────────────────────────────────────
//
// Bear stores notes in a SQLite database at:
//   ~/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data/database.sqlite
//
// No public API — we read the SQLite file directly (with user consent via a
// file picker in Swift that passes us the path).
//
// Key Bear tables (schema may vary by Bear version — read scrupulously):
//   ZSFNOTE        — notes (title, text in Markdown, creation/modification dates)
//   ZSFNOTETAG     — join table note ↔ tag
//   ZSFTAG         — tag names (hierarchical: "swift/ios" = parent "swift", child "ios")
//   ZSFNOTEFILE    — attached files / images
//
// Pipeline:
//   → open Bear's SQLite (read-only)
//   → read ZSFNOTE rows (skip trashed notes: ZTRASHED = 1)
//   → parse Bear's Markdown subset → Pinkha BlockContent list
//   → persist as Pinkha documents
//
// Submodules (to be implemented):
//   reader.rs  — rusqlite read-only connection to Bear's DB
//   schema.rs  — Bear SQLite row types
//   mapper.rs  — Bear Markdown → Pinkha domain types

// pub mod reader;   // ← uncomment when implementing
// pub mod schema;
// pub mod mapper;

use crate::application::database_repository::DatabaseRepository;
use crate::application::repository::DocumentRepository;
use crate::extractors::{ExtractorError, ImportResult};
use crate::extractors::traits::Extractor;

// ── Config ────────────────────────────────────────────────────────────────────

/// Input required to run a Bear import.
///
/// Swift presents a file picker scoped to Bear's group container, then passes
/// the resolved path here. Pinkha opens the file read-only.
pub struct BearConfig {
    /// Absolute path to Bear's `database.sqlite` file.
    pub db_path: String,
}

// ── Extractor ─────────────────────────────────────────────────────────────────

pub struct BearExtractor;

impl BearExtractor {
    pub fn new() -> Self {
        Self
    }
}

impl Default for BearExtractor {
    fn default() -> Self {
        Self::new()
    }
}

impl Extractor for BearExtractor {
    type Config = BearConfig;

    fn app_name(&self) -> &'static str {
        "Bear"
    }

    async fn run(
        &self,
        _config: BearConfig,
        _docs: &(dyn DocumentRepository + Send + Sync),
        _dbs: &(dyn DatabaseRepository + Send + Sync),
    ) -> Result<ImportResult, ExtractorError> {
        // Implementation order:
        //   1. reader.rs  — open Bear SQLite read-only, enumerate ZSFNOTE rows
        //   2. schema.rs  — map ZSFNOTE columns to a BearNote struct
        //   3. mapper.rs  — parse Bear Markdown subset → Vec<BlockContent>
        //                   map ZSFTAG hierarchy to Pinkha selection properties
        todo!("BearExtractor — implementation in progress")
    }
}
