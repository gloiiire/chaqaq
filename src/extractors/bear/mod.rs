// ── Bear extractor ────────────────────────────────────────────────────────────
//
// Bear stores notes in a SQLite book at:
//   ~/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data/book.sqlite
//
// No public API — we read the SQLite file directly (with user consent via a
// file picker in Swift that passes us the path).
//
// Pipeline:
//   → open Bear's SQLite (read-only)
//   → read ZSFNOTE rows (skip trashed notes: ZTRASHED = 1)
//   → parse Bear's Markdown subset → Pinkha BlockContent list
//   → persist as Pinkha leaves

pub mod mapper;
pub mod reader;
pub mod schema;

use crate::application::book_repository::BookRepository;
use crate::application::shelf_repository::ShelfRepository;
use crate::application::repository::LeafRepository;
use crate::application::use_cases;
use crate::domain::leaf::Block;
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
    /// Absolute path to Bear's `book.sqlite` file.
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
        docs: &(dyn LeafRepository + Send + Sync),
        dbs: &(dyn BookRepository + Send + Sync),
        _shelves: &(dyn ShelfRepository + Send + Sync),
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

            let uow = NoOpUnitOfWork::with_leaves_books(docs, dbs);
            let mut doc = use_cases::create_leaf(&uow, title)?;
            // Imports default to locked = true so the user reads the
            // extracted content before editing. Set in-memory before the
            // save below so it's persisted in one write rather than a
            // round-trip via `update_leaf_locked`.
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
            book_id: None,
            leaves: notes.len(),
            entries: 0,
            blocks: total_blocks,
            skipped: 0,
        })
    }
}
