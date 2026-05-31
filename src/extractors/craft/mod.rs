// ── Craft extractor ───────────────────────────────────────────────────────────
//
// Reads Craft's local `.realm` file directly (no network, no API token).
// Craft uses Realm SDK 5+ ("cluster tree" format), supported by realm-codec.
//
// Pipeline:
//   → RealmFile::open(db_path)
//   → read class_BlockDataModel  (all blocks: id, content, type, rawProperties)
//   → detect page boundaries via rawProperties.titleEnabled == "true"
//   → create one pinkha Document per title block; content blocks follow
//   → persist via DocumentRepository

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

/// Input required to run a Craft import.
///
/// Swift presents a file picker scoped to Craft's container, then passes the
/// resolved path here. Pinkha opens the file read-only via realm-codec.
pub struct CraftConfig {
    /// Absolute path to Craft's `*.realm` file.
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

        let table = realm
            .table("class_BlockDataModel")
            .ok_or_else(|| ExtractorError::Parse("BlockDataModel table not found".into()))?;

        let content_idx = table
            .column_index("content")
            .ok_or_else(|| ExtractorError::Parse("content column missing".into()))?;
        let type_idx = table
            .column_index("type")
            .ok_or_else(|| ExtractorError::Parse("type column missing".into()))?;
        let raw_props_idx = table
            .column_index("rawProperties")
            .ok_or_else(|| ExtractorError::Parse("rawProperties column missing".into()))?;

        // Accumulate blocks for the current in-progress document.
        let mut pending_title: Option<String> = None;
        let mut pending_blocks: Vec<BlockContent> = vec![];
        let mut doc_count: usize = 0;
        let mut block_count: usize = 0;
        let mut skipped: usize = 0;

        for row in &table.rows {
            let content = row.get(content_idx).as_str().to_owned();
            let block_type = row.get(type_idx).as_str();
            let raw_props = row.get(raw_props_idx).as_str();

            if is_title_block(raw_props) {
                // Flush the previous document before starting a new one.
                if let Some(title) = pending_title.take() {
                    flush_document(docs, &title, pending_blocks.drain(..).collect())?;
                    doc_count += 1;
                } else {
                    pending_blocks.clear();
                }
                let title = if content.is_empty() { "Untitled".to_string() } else { content };
                pending_title = Some(title);
            } else {
                match map_block(&content, block_type) {
                    Some(bc) => {
                        pending_blocks.push(bc);
                        block_count += 1;
                    }
                    None => {
                        skipped += 1;
                    }
                }
            }
        }

        // Flush the last open document.
        if let Some(title) = pending_title.take() {
            flush_document(docs, &title, pending_blocks.drain(..).collect())?;
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

/// A block whose `rawProperties` JSON contains `"titleEnabled": "true"` marks
/// the beginning of a new Craft page (document).
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

/// Map a Craft block type + content to a pinkha `BlockContent`.
///
/// Returns `None` for types without a pinkha equivalent (image, url, file,
/// table) so they can be counted as skipped.
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
        // Empty text blocks are preserved (blank paragraph).
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
