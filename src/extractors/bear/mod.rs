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

pub mod mapper;
pub mod reader;
pub mod schema;

use crate::application::database_repository::DatabaseRepository;
use crate::application::folder_repository::FolderRepository;
use crate::application::repository::DocumentRepository;
use crate::application::use_cases;
use crate::domain::document::Block;
use crate::extractors::traits::Extractor;
use crate::extractors::{ExtractorError, ImportResult};
use crate::infrastructure::no_op_unit_of_work::NoOpUnitOfWork;

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
        _folders: &(dyn FolderRepository + Send + Sync),
    ) -> Result<ImportResult, ExtractorError> {
        let _ = dbs;

        let reader = BearReader::new(&config.db_path)?;
        let notes = reader.fetch_notes()?;

        let mut total_blocks: usize = 0;

        for note in &notes {
            let title = if note.title.is_empty() {
                "Untitled"
            } else {
                &note.title
            };

            let uow = NoOpUnitOfWork::with_docs_dbs(docs, dbs);
            let mut doc = use_cases::create_document(&uow, title)?;
            // Imports default to locked = true so the user reads the
            // extracted content before editing. Set in-memory before the
            // save below so it's persisted in one write rather than a
            // round-trip via `update_document_locked`.
            doc.locked = true;
            let parsed_blocks = parse_note_blocks(&note.text);
            let block_count = parsed_blocks.len();

            for parsed in parsed_blocks {
                let mut block = Block::new(parsed.content);
                for child_content in parsed.children {
                    block.children.push(Block::new(child_content));
                }
                doc.blocks.push(block);
            }
            docs.save(&doc)?;

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
