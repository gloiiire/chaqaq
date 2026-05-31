// ── Craft extractor ───────────────────────────────────────────────────────────
//
// Reads Craft's local `.realm` file directly (no network, no API token).
// Craft uses Realm SDK 5+ ("cluster tree" format), supported by realm-codec.
//
// Pipeline:
//   → RealmFile::open(db_path)
//   → read class_DocumentDataModel  → collect the 226 real document IDs
//   → read class_BlockDataModel     → group blocks by lastSyncedBlockIds (= doc ID)
//   → for each doc: title block (titleEnabled) + content blocks
//   → persist one pinkha Document per Craft document

use std::collections::HashMap;

use realm_codec::RealmFile;
use serde_json::Value as JsonValue;

use crate::application::database_repository::DatabaseRepository;
use crate::application::repository::DocumentRepository;
use crate::application::use_cases;
use crate::domain::document::BlockContent;
use crate::extractors::traits::Extractor;
use crate::extractors::{ExtractorError, ImportResult};
use chaqaq::InlineText;

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
        let raw_props_idx = block_table
            .column_index("rawProperties")
            .ok_or_else(|| ExtractorError::Parse("rawProperties column missing".into()))?;
        let lsb_idx = block_table
            .column_index("lastSyncedBlockIds")
            .ok_or_else(|| ExtractorError::Parse("lastSyncedBlockIds column missing".into()))?;

        // doc_id → (title, content_blocks, skipped_count)
        let mut doc_map: HashMap<String, (Option<String>, Vec<BlockContent>, usize)> =
            HashMap::new();

        for row in &block_table.rows {
            let doc_id = row.get(lsb_idx).as_str().to_lowercase();
            if doc_id.is_empty() || !doc_ids.contains(&doc_id) {
                continue;
            }

            let content = row.get(content_idx).as_str().to_owned();
            let block_type = row.get(type_idx).as_str();
            let raw_props = row.get(raw_props_idx).as_str();

            let entry = doc_map.entry(doc_id).or_insert((None, vec![], 0));

            if is_title_block(raw_props) {
                // Only keep the first title block as the document title.
                if entry.0.is_none() {
                    let first_line = content.lines().next().unwrap_or("").trim().to_string();
                    entry.0 = Some(if first_line.is_empty() {
                        "Untitled".to_string()
                    } else {
                        first_line
                    });
                }
            } else {
                match map_block(&content, block_type) {
                    Some(bc) => entry.1.push(bc),
                    None => entry.2 += 1,
                }
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
            flush_document(docs, &title, blocks)?;
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

fn is_title_block(raw_props: &str) -> bool {
    if raw_props.is_empty() || raw_props == "{}" {
        return false;
    }
    if let Ok(v) = serde_json::from_str::<JsonValue>(raw_props) {
        if let Some(te) = v.get("titleEnabled") {
            return te.as_str() == Some("true") || te.as_bool() == Some(true);
        }
    }
    false
}

fn map_block(content: &str, block_type: &str) -> Option<BlockContent> {
    match block_type {
        "text" => Some(BlockContent::Text(plain(content))),
        "code" => {
            if content.is_empty() {
                return None;
            }
            Some(BlockContent::Code { language: String::new(), text: content.to_string() })
        }
        "line" => Some(BlockContent::Divider),
        _ => None,
    }
}

fn plain(s: &str) -> Vec<InlineText> {
    vec![InlineText { content: s.to_string(), styles: vec![] }]
}

fn flush_document(
    docs: &(dyn DocumentRepository + Send + Sync),
    title: &str,
    blocks: Vec<BlockContent>,
) -> Result<(), ExtractorError> {
    let doc = use_cases::create_document(docs, title)?;
    if blocks.is_empty() {
        return Ok(());
    }
    let mut full_doc = docs.load(doc.id)?;
    for bc in blocks {
        full_doc.add_block(bc);
    }
    docs.save(&full_doc)?;
    Ok(())
}

// ── Unit tests ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_title_block_detects_string_true() {
        assert!(is_title_block(r#"{"titleEnabled":"true"}"#));
    }

    #[test]
    fn is_title_block_detects_bool_true() {
        assert!(is_title_block(r#"{"titleEnabled":true}"#));
    }

    #[test]
    fn is_title_block_rejects_empty() {
        assert!(!is_title_block(""));
        assert!(!is_title_block("{}"));
    }

    #[test]
    fn is_title_block_rejects_false() {
        assert!(!is_title_block(r#"{"titleEnabled":"false"}"#));
        assert!(!is_title_block(r#"{"titleEnabled":false}"#));
    }

    #[test]
    fn is_title_block_rejects_no_key() {
        assert!(!is_title_block(r#"{"coverImageUrl":"https://example.com"}"#));
    }

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
}
