// ── Bear extractor ────────────────────────────────────────────────────────────
//
// Bear stores notes in a SQLite database at:
//   ~/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data/database.sqlite
//
// No public API — we read the SQLite file directly (with user consent via a
// file picker in Swift that passes us the path).
//
// Pipeline:
//   → open Bear's SQLite (read-only)
//   → read ZSFNOTE rows (skip trashed notes: ZTRASHED = 1)
//   → parse Bear's Markdown subset → Pinkha BlockContent list
//   → persist as Pinkha documents

pub mod reader;
pub mod schema;
pub mod mapper;

use crate::application::database_repository::DatabaseRepository;
use crate::application::repository::DocumentRepository;
use crate::application::use_cases;
use crate::extractors::traits::Extractor;
use crate::extractors::{ExtractorError, ImportResult};

use self::mapper::parse_note_blocks;
use self::reader::BearReader;

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
        config: BearConfig,
        docs: &(dyn DocumentRepository + Send + Sync),
        dbs: &(dyn DatabaseRepository + Send + Sync),
    ) -> Result<ImportResult, ExtractorError> {
        // Unused — Bear produces only documents, no databases.
        let _ = dbs;

        // 1. Open Bear's SQLite in read-only mode.
        let reader = BearReader::new(&config.db_path)?;

        // 2. Fetch all non-trashed notes.
        let notes = reader.fetch_notes()?;

        let mut total_blocks: usize = 0;

        // 3. Import each note as a Pinkha document.
        for note in &notes {
            // Use the Bear title as the Pinkha document title.
            let title = if note.title.is_empty() {
                "Untitled"
            } else {
                &note.title
            };

            // Create the document (this does one save with title only).
            let doc = use_cases::create_document(docs, title)?;
            let doc_id = doc.id;

            // Parse the note body into blocks.
            let block_contents = parse_note_blocks(&note.text);
            let block_count = block_contents.len();

            // Bulk in-memory update: load → push all blocks → save once.
            if !block_contents.is_empty() {
                let mut full_doc = docs.load(doc_id)?;
                for content in block_contents {
                    full_doc.add_block(content);
                }
                docs.save(&full_doc)?;
            }

            total_blocks += block_count;
        }

        Ok(ImportResult {
            app: "Bear",
            database_id: None,
            documents: notes.len(),
            entries: 0,
            blocks: total_blocks,
            skipped: 0,
        })
    }
}
