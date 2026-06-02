// ── Craft extractor ───────────────────────────────────────────────────────────
//
// Reads Craft's local `.realm` file directly (no network, no API token).
// Craft uses Realm SDK 5+ ("cluster tree" format), supported by realm-codec.
//
// Pipeline:
//   → RealmFile::open(db_path)
//   → read class_DocumentDataModel  → collect the 226 real document IDs
//   → read class_BlockDataModel     → group blocks by lastSyncedBlockIds (= doc ID)
//   → for each doc: first non-empty block → title, remaining blocks → content
//   → persist one pinkha Document per Craft document

use std::collections::HashMap;

use realm_codec::RealmFile;

use crate::application::database_repository::DatabaseRepository;
use crate::application::folder_repository::FolderRepository;
use crate::application::repository::DocumentRepository;
use crate::application::use_cases;
use crate::domain::document::{Block, BlockContent};
use crate::extractors::bear::mapper::ParsedBlock;
use crate::extractors::traits::Extractor;
use crate::extractors::{ExtractorError, ImportResult};
use crate::infrastructure::no_op_unit_of_work::NoOpUnitOfWork;
use chaqaq::InlineText;
use uuid::Uuid;

// ── Config ────────────────────────────────────────────────────────────────────

pub struct CraftConfig {
    pub db_path: String,
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

    async fn run(
        &self,
        config: CraftConfig,
        docs: &(dyn DocumentRepository + Send + Sync),
        _dbs: &(dyn DatabaseRepository + Send + Sync),
        _folders: &(dyn FolderRepository + Send + Sync),
    ) -> Result<ImportResult, ExtractorError> {
        let realm = RealmFile::open(&config.db_path)
            .map_err(|e| ExtractorError::Parse(format!("cannot open realm file: {e}")))?;

        // ── Step 1: collect real document IDs from DocumentDataModel ──────────
        let doc_ids: std::collections::HashSet<String> = {
            let doc_table = realm
                .table("class_DocumentDataModel")
                .ok_or_else(|| ExtractorError::Parse("DocumentDataModel table not found".into()))?;
            let id_col = doc_table
                .column_index("id")
                .ok_or_else(|| ExtractorError::Parse("DocumentDataModel.id missing".into()))?;
            doc_table
                .rows
                .iter()
                .map(|r| r.get(id_col).as_str().to_lowercase())
                .filter(|s| !s.is_empty())
                .collect()
        };

        // ── Step 2: group blocks by document ─────────────────────────────────
        //
        // `lastSyncedBlockIds` stores the DocumentDataModel.id for every block
        // (confirmed: 226 unique values = 226 documents, all 6763 blocks matched).
        let block_table = realm
            .table("class_BlockDataModel")
            .ok_or_else(|| ExtractorError::Parse("BlockDataModel table not found".into()))?;

        let content_idx = block_table
            .column_index("content")
            .ok_or_else(|| ExtractorError::Parse("content column missing".into()))?;
        let type_idx = block_table
            .column_index("type")
            .ok_or_else(|| ExtractorError::Parse("type column missing".into()))?;
        let lsb_idx = block_table
            .column_index("lastSyncedBlockIds")
            .ok_or_else(|| ExtractorError::Parse("lastSyncedBlockIds column missing".into()))?;
        // Best-effort block colour column. Craft's exact schema is not fully
        // documented from the outside, so we probe a handful of plausible
        // names and pick the first that exists. `None` means the column wasn't
        // found in this Craft version — import keeps working, just without
        // colour fidelity. Add candidates here as the real schema is mapped.
        let color_idx = [
            "highlightColor",
            "textColor",
            "colorName",
            "color",
            "blockColor",
        ]
        .iter()
        .find_map(|name| block_table.column_index(name));

        // doc_id → (title, content_blocks, skipped_count)
        let mut doc_map: HashMap<String, (Option<String>, Vec<ParsedBlock>, usize)> =
            HashMap::new();

        for row in &block_table.rows {
            let doc_id = row.get(lsb_idx).as_str().to_lowercase();
            if doc_id.is_empty() || !doc_ids.contains(&doc_id) {
                continue;
            }

            let content = row.get(content_idx).as_str().to_owned();
            let block_type = row.get(type_idx).as_str();

            let entry = doc_map.entry(doc_id).or_insert((None, vec![], 0));

            // Title: first "text" block with non-empty content, first line only.
            if entry.0.is_none()
                && let Some(t) = title_candidate(&content, block_type)
            {
                entry.0 = Some(t);
                continue; // consumed as title, don't duplicate in content
            }

            let color = color_idx
                .map(|idx| row.get(idx).as_str())
                .filter(|s| !s.is_empty())
                .and_then(craft_color_name_to_pinkha);

            match map_block(&content, block_type) {
                Some(bc) => entry.1.push(ParsedBlock {
                    content: bc,
                    children: vec![],
                    color,
                }),
                None => entry.2 += 1,
            }
        }

        // ── Step 3: persist one pinkha Document per Craft document ────────────
        let mut doc_count = 0usize;
        let mut block_count = 0usize;
        let mut skipped = 0usize;

        for (_doc_id, (title_opt, blocks, doc_skipped)) in doc_map {
            let title = title_opt.unwrap_or_else(|| "Untitled".to_string());
            block_count += blocks.len();
            skipped += doc_skipped;
            flush_document(docs, &title, blocks, None)?;
            doc_count += 1;
        }

        Ok(ImportResult {
            app: "Craft",
            database_id: None,
            documents: doc_count,
            entries: 0,
            blocks: block_count,
            skipped,
        })
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

// Returns the title candidate from a block: only "text" blocks qualify,
// and only the first non-empty trimmed line is used.
pub fn title_candidate(content: &str, block_type: &str) -> Option<String> {
    if block_type != "text" {
        return None;
    }
    let line = content.lines().next().unwrap_or("").trim();
    if line.is_empty() {
        None
    } else {
        Some(line.to_string())
    }
}

pub fn map_block(content: &str, block_type: &str) -> Option<BlockContent> {
    match block_type {
        "text" => Some(BlockContent::Text(plain(content))),
        "code" => {
            if content.is_empty() {
                return None;
            }
            Some(BlockContent::Code {
                language: String::new(),
                text: content.to_string(),
            })
        }
        "line" => Some(BlockContent::Divider),
        _ => None,
    }
}

pub fn plain(s: &str) -> Vec<InlineText> {
    vec![InlineText {
        content: s.to_string(),
        styles: vec![],
    }]
}

pub fn flush_document(
    docs: &(dyn DocumentRepository + Send + Sync),
    title: &str,
    blocks: Vec<ParsedBlock>,
    folder_id: Option<Uuid>,
) -> Result<(), ExtractorError> {
    let uow = NoOpUnitOfWork::with_docs(docs);
    let mut doc = use_cases::create_document(&uow, title)?;
    for parsed in blocks {
        let mut block = Block::new(parsed.content);
        block.color = parsed.color;
        for child_content in parsed.children {
            block.children.push(Block::new(child_content));
        }
        doc.blocks.push(block);
    }
    if let Some(fid) = folder_id {
        doc.folder_id = Some(fid);
    }
    docs.save(&doc)?;
    Ok(())
}

/// Maps a Craft colour string (whatever encoding the realm column uses) to a
/// Pinkha colour name. Returns `None` for unknown values so we never
/// misclassify — better to lose colour fidelity than paint a block the wrong
/// hue.
///
/// Best-effort: the actual values shipped by Craft are not fully documented
/// externally. This mapping covers the obvious case (English colour names,
/// case-insensitive). Extend as new observed values surface in real imports.
pub fn craft_color_name_to_pinkha(raw: &str) -> Option<String> {
    match raw.to_ascii_lowercase().as_str() {
        "red" => Some("red".into()),
        "pink" => Some("pink".into()),
        "orange" => Some("orange".into()),
        "yellow" => Some("yellow".into()),
        "green" => Some("green".into()),
        "cyan" | "teal" => Some("cyan".into()),
        "blue" => Some("blue".into()),
        "purple" | "violet" => Some("purple".into()),
        "brown" => Some("brown".into()),
        _ => None,
    }
}

// ── Unit tests ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn map_block_text_plain() {
        let bc = map_block("Hello world", "text");
        assert!(matches!(bc, Some(BlockContent::Text(_))));
        if let Some(BlockContent::Text(spans)) = bc {
            assert_eq!(spans[0].content, "Hello world");
        }
    }

    #[test]
    fn map_block_text_empty_ok() {
        assert!(matches!(map_block("", "text"), Some(BlockContent::Text(_))));
    }

    #[test]
    fn map_block_code_non_empty() {
        let bc = map_block("let x = 1;", "code");
        assert!(matches!(bc, Some(BlockContent::Code { .. })));
        if let Some(BlockContent::Code { text, language }) = bc {
            assert_eq!(text, "let x = 1;");
            assert_eq!(language, "");
        }
    }

    #[test]
    fn map_block_code_empty_skipped() {
        assert!(map_block("", "code").is_none());
    }

    #[test]
    fn map_block_line_divider() {
        assert!(matches!(map_block("", "line"), Some(BlockContent::Divider)));
    }

    #[test]
    fn map_block_image_skipped() {
        assert!(map_block("", "image").is_none());
    }

    #[test]
    fn map_block_url_skipped() {
        assert!(map_block("https://example.com", "url").is_none());
    }

    #[test]
    fn title_candidate_text_returns_first_line() {
        assert_eq!(
            title_candidate("Hello\nworld", "text").as_deref(),
            Some("Hello")
        );
    }

    #[test]
    fn title_candidate_text_trims_whitespace() {
        assert_eq!(
            title_candidate("  Hello  \nworld", "text").as_deref(),
            Some("Hello")
        );
    }

    #[test]
    fn title_candidate_code_skipped() {
        assert!(title_candidate("let x = 1;", "code").is_none());
    }

    #[test]
    fn title_candidate_image_skipped() {
        assert!(title_candidate("", "image").is_none());
    }

    #[test]
    fn title_candidate_empty_text_skipped() {
        assert!(title_candidate("", "text").is_none());
    }

    #[test]
    fn title_candidate_whitespace_only_skipped() {
        assert!(title_candidate("   \n  text", "text").is_none());
    }

    // ── craft_color_name_to_pinkha ───────────────────────────────────────────

    #[test]
    fn craft_color_red_maps_to_pinkha_red() {
        assert_eq!(craft_color_name_to_pinkha("red").as_deref(), Some("red"));
        // Case-insensitive.
        assert_eq!(craft_color_name_to_pinkha("RED").as_deref(), Some("red"));
        assert_eq!(craft_color_name_to_pinkha("Red").as_deref(), Some("red"));
    }

    #[test]
    fn craft_color_synonyms_collapse_correctly() {
        assert_eq!(craft_color_name_to_pinkha("teal").as_deref(), Some("cyan"));
        assert_eq!(
            craft_color_name_to_pinkha("violet").as_deref(),
            Some("purple")
        );
    }

    #[test]
    fn craft_color_unknown_returns_none() {
        // Unknown values must not be silently misclassified — better to lose
        // colour fidelity than to paint a block the wrong hue.
        assert!(craft_color_name_to_pinkha("").is_none());
        assert!(craft_color_name_to_pinkha("highlight-yellow-2").is_none());
        assert!(craft_color_name_to_pinkha("#FF0000").is_none());
    }
}
