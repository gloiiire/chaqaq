// ── Craft Combined extractor ──────────────────────────────────────────────────
//
// Merges Craft's `.realm` database with a folder of `.textbundle` exports.
//
// Strategy:
//   1. Walk textbundle folder → build map (normalized title → display title + path)
//   2. Open realm → group blocks per document (same logic as CraftExtractor)
//   3. For each realm document:
//      - If a textbundle with matching title exists → import using textbundle
//        markdown content and the filename stem as the display title.
//      - Otherwise → import using realm block content.
//   4. Import any textbundles that had no corresponding realm page.
//
// Result: full coverage, no duplicates, textbundle content preferred when
// available (richer markdown fidelity, reliable filename-based title).

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use realm_codec::RealmFile;

use crate::application::database_repository::DatabaseRepository;
use crate::application::repository::DocumentRepository;
use crate::extractors::bear::mapper::parse_note_blocks;
use crate::extractors::craft::{flush_document, map_block, title_candidate};
use crate::extractors::craft_textbundle::{find_textbundles, textbundle_title};
use crate::extractors::traits::Extractor;
use crate::extractors::{ExtractorError, ImportResult};

// ── Config ────────────────────────────────────────────────────────────────────

pub struct CraftCombinedConfig {
    /// Absolute path to Craft's `.realm` file.
    pub realm_path: String,
    /// Absolute path to the root folder containing `.textbundle` packages.
    pub textbundle_root: String,
}

// ── Extractor ─────────────────────────────────────────────────────────────────

pub struct CraftCombinedExtractor;

impl CraftCombinedExtractor {
    pub fn new() -> Self {
        Self
    }
}

impl Default for CraftCombinedExtractor {
    fn default() -> Self {
        Self::new()
    }
}

impl Extractor for CraftCombinedExtractor {
    type Config = CraftCombinedConfig;

    fn app_name(&self) -> &'static str {
        "Craft (Combined)"
    }

    async fn run(
        &self,
        config: CraftCombinedConfig,
        docs: &(dyn DocumentRepository + Send + Sync),
        _dbs: &(dyn DatabaseRepository + Send + Sync),
    ) -> Result<ImportResult, ExtractorError> {
        // ── Step 1: index textbundles by normalized title ─────────────────────
        let tb_root = Path::new(&config.textbundle_root);
        let bundles = find_textbundles(tb_root);

        // normalized_title → (display_title, bundle_path)
        let mut tb_map: HashMap<String, (String, PathBuf)> = HashMap::new();
        for bundle in &bundles {
            let title = textbundle_title(bundle);
            tb_map
                .entry(normalize(&title))
                .or_insert_with(|| (title, bundle.clone()));
        }

        // ── Step 2: open realm + collect document IDs ─────────────────────────
        let realm = RealmFile::open(&config.realm_path)
            .map_err(|e| ExtractorError::Parse(format!("cannot open realm file: {e}")))?;

        let doc_ids: HashSet<String> = {
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

        // ── Step 3: group realm blocks by document ────────────────────────────
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

        // doc_id → (title_opt, content_blocks, skipped_count)
        let mut doc_map: HashMap<String, (Option<String>, Vec<_>, usize)> = HashMap::new();

        for row in &block_table.rows {
            let doc_id = row.get(lsb_idx).as_str().to_lowercase();
            if doc_id.is_empty() || !doc_ids.contains(&doc_id) {
                continue;
            }
            let content = row.get(content_idx).as_str().to_owned();
            let block_type = row.get(type_idx).as_str();
            let entry = doc_map.entry(doc_id).or_insert((None, vec![], 0));

            if entry.0.is_none() {
                if let Some(t) = title_candidate(&content, block_type) {
                    entry.0 = Some(t);
                    continue;
                }
            }
            match map_block(&content, block_type) {
                Some(bc) => entry.1.push(bc),
                None => entry.2 += 1,
            }
        }

        // ── Step 4: persist, preferring textbundle when title matches ─────────
        let mut doc_count = 0usize;
        let mut block_count = 0usize;
        let mut skipped = 0usize;
        let mut matched_tb_keys: HashSet<String> = HashSet::new();

        for (_doc_id, (title_opt, realm_blocks, doc_skipped)) in doc_map {
            let realm_title = title_opt.unwrap_or_else(|| "Untitled".to_string());
            let key = normalize(&realm_title);

            if let Some((tb_title, bundle_path)) = tb_map.get(&key) {
                // Textbundle match: use markdown content + filename title.
                let md = std::fs::read_to_string(bundle_path.join("text.markdown"))
                    .unwrap_or_default();
                let blocks = parse_note_blocks(&md);
                block_count += blocks.len();
                flush_document(docs, tb_title, blocks)?;
                matched_tb_keys.insert(key);
            } else {
                // Realm-only page: use realm block content.
                block_count += realm_blocks.len();
                skipped += doc_skipped;
                flush_document(docs, &realm_title, realm_blocks)?;
            }
            doc_count += 1;
        }

        // ── Step 5: import textbundles with no realm counterpart ──────────────
        for bundle in &bundles {
            let title = textbundle_title(bundle);
            if matched_tb_keys.contains(&normalize(&title)) {
                continue;
            }
            let md = std::fs::read_to_string(bundle.join("text.markdown")).unwrap_or_default();
            let blocks = parse_note_blocks(&md);
            block_count += blocks.len();
            flush_document(docs, &title, blocks)?;
            doc_count += 1;
        }

        Ok(ImportResult {
            app: "Craft (Combined)",
            database_id: None,
            documents: doc_count,
            entries: 0,
            blocks: block_count,
            skipped,
        })
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn normalize(title: &str) -> String {
    title.trim().to_lowercase()
}

// ── Unit tests ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_trims_and_lowercases() {
        assert_eq!(normalize("  Hello World  "), "hello world");
    }

    #[test]
    fn normalize_empty() {
        assert_eq!(normalize(""), "");
    }

    #[test]
    fn normalize_emoji_preserved() {
        assert_eq!(normalize("Courses 🏡"), "courses 🏡");
    }
}
