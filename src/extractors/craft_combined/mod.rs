// ── Craft Combined extractor ──────────────────────────────────────────────────
//
// Merges Craft's `.realm` book with a shelf of `.textbundle` exports.
//
// Strategy:
//   1. Walk textbundle shelf → build map (normalized title → display title + path)
//   2. Open realm → group blocks per leaf (same logic as CraftExtractor)
//   3. For each realm leaf:
//      - If a textbundle with matching title exists → import using textbundle
//        markdown content and the filename stem as the display title.
//      - Otherwise → import using realm block content.
//   4. Import any textbundles that had no corresponding realm page.
//
// Result: full coverage, no duplicates, textbundle content preferred when
// available (richer markdown fidelity, reliable filename-based title).
//
// Matching is done on normalized titles (see `normalize()`):
//   - lowercase + trim
//   - leading Markdown heading markers stripped ("# ", "## ", "### ")
//   - trailing Craft dedup suffix stripped (" (1)", " (2)", …)

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use crate::application::book_repository::BookRepository;
use crate::application::repository::LeafRepository;
use crate::application::shelf_repository::ShelfRepository;
use crate::extractors::bear::mapper::{ParsedBlock, parse_note_blocks};
use crate::extractors::craft::{flush_leaf, map_block, title_candidate};
use crate::extractors::craft_textbundle::{
    find_textbundles, relative_shelf_components, textbundle_title,
};
use crate::extractors::traits::Extractor;
use crate::extractors::{ExtractorError, ImportResult};
use uuid::Uuid;

// ── Config ────────────────────────────────────────────────────────────────────

pub struct CraftCombinedConfig {
    /// Absolute path to Craft's `.realm` file.
    pub realm_path: String,
    /// Absolute path to the root shelf containing `.textbundle` packages.
    pub textbundle_root: String,
}

// ── Breakdown ─────────────────────────────────────────────────────────────────

/// Per-source breakdown returned by `run_detailed`.
pub struct CraftCombinedBreakdown {
    /// Pages imported via matching textbundle content (best quality).
    pub matched_textbundle: usize,
    /// Realm pages with no matching textbundle (fallback to realm blocks).
    pub realm_fallback: usize,
    /// Textbundles with no matching realm page (imported as-is).
    pub textbundle_only: usize,
}

// ── Extractor ─────────────────────────────────────────────────────────────────

pub struct CraftCombinedExtractor;

impl CraftCombinedExtractor {
    pub fn new() -> Self {
        Self
    }

    /// Full import with per-source breakdown statistics.
    pub async fn run_detailed(
        &self,
        config: CraftCombinedConfig,
        docs: &(dyn LeafRepository + Send + Sync),
        dbs: &(dyn BookRepository + Send + Sync),
        shelves: &(dyn ShelfRepository + Send + Sync),
    ) -> Result<(ImportResult, CraftCombinedBreakdown), ExtractorError> {
        let _ = dbs;

        // ── Step 1: index textbundles by normalized title ─────────────────────
        let tb_root = Path::new(&config.textbundle_root);
        if !tb_root.exists() {
            return Err(ExtractorError::Parse(format!(
                "textbundle root does not exist: {}",
                config.textbundle_root
            )));
        }
        if !tb_root.is_dir() {
            return Err(ExtractorError::Parse(format!(
                "textbundle root is not a directory: {}",
                config.textbundle_root
            )));
        }
        let bundles = find_textbundles(tb_root);

        // normalized_title → (display_title, bundle_path)
        let mut tb_map: HashMap<String, (String, PathBuf)> = HashMap::new();
        for bundle in &bundles {
            let title = textbundle_title(bundle);
            tb_map
                .entry(normalize(&title))
                .or_insert_with(|| (title, bundle.clone()));
        }

        let mut shelf_cache: HashMap<Vec<String>, Uuid> = HashMap::new();

        // ── Step 2: open realm + collect leaf IDs ─────────────────────────
        let realm = crate::extractors::open_realm_guarded(&config.realm_path)?;

        let leaf_ids: HashSet<String> = {
            let leaf_table = realm
                .table("class_DocumentDataModel")
                .ok_or_else(|| ExtractorError::Parse("DocumentDataModel table not found".into()))?;
            let id_col = leaf_table
                .column_index("id")
                .ok_or_else(|| ExtractorError::Parse("DocumentDataModel.id missing".into()))?;
            leaf_table
                .rows
                .iter()
                .map(|r| r.get(id_col).as_str().to_lowercase())
                .filter(|s| !s.is_empty())
                .collect()
        };

        // ── Step 3: group realm blocks by leaf ────────────────────────────
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

        // leaf_id → (title_opt, content_blocks, skipped_count)
        let mut leaf_map: HashMap<String, (Option<String>, Vec<ParsedBlock>, usize)> =
            HashMap::new();

        for row in &block_table.rows {
            let leaf_id = row.get(lsb_idx).as_str().to_lowercase();
            if leaf_id.is_empty() || !leaf_ids.contains(&leaf_id) {
                continue;
            }
            let content = row.get(content_idx).as_str().to_owned();
            let block_type = row.get(type_idx).as_str();
            let entry = leaf_map.entry(leaf_id).or_insert((None, vec![], 0));

            if entry.0.is_none()
                && let Some(t) = title_candidate(&content, block_type)
            {
                entry.0 = Some(t);
                continue;
            }
            match map_block(&content, block_type) {
                // craft_combined doesn't yet probe the colour column —
                // colour fidelity here is a future iteration once textbundle
                // parsing also exposes block colours. See `craft::run` for
                // the per-block colour probing pattern.
                Some(bc) => entry.1.push(ParsedBlock {
                    content: bc,
                    children: vec![],
                    color: None,
                }),
                None => entry.2 += 1,
            }
        }

        // ── Step 4: persist, preferring textbundle when title matches ─────────
        let mut block_count = 0usize;
        let mut skipped = 0usize;
        let mut matched_tb_keys: HashSet<String> = HashSet::new();
        let mut tb_matched_count = 0usize;
        let mut realm_fallback_count = 0usize;

        for (_leaf_id, (title_opt, realm_blocks, leaf_skipped)) in leaf_map {
            let realm_title = title_opt.unwrap_or_else(|| "Untitled".to_string());
            let key = normalize(&realm_title);

            if let Some((tb_title, bundle_path)) = tb_map.get(&key) {
                let md =
                    std::fs::read_to_string(bundle_path.join("text.markdown")).unwrap_or_default();
                let blocks = parse_note_blocks(&md);
                block_count += blocks.len();
                let components = relative_shelf_components(bundle_path, tb_root);
                let shelf_id = ensure_shelf_cached(&components, shelves, &mut shelf_cache)?;
                flush_leaf(docs, tb_title, blocks, shelf_id)?;
                matched_tb_keys.insert(key);
                tb_matched_count += 1;
            } else {
                block_count += realm_blocks.len();
                skipped += leaf_skipped;
                flush_leaf(docs, &realm_title, realm_blocks, None)?;
                realm_fallback_count += 1;
            }
        }

        // ── Step 5: import textbundles with no realm counterpart ──────────────
        let mut tb_only_count = 0usize;

        for bundle in &bundles {
            let title = textbundle_title(bundle);
            if matched_tb_keys.contains(&normalize(&title)) {
                continue;
            }
            let md = std::fs::read_to_string(bundle.join("text.markdown")).unwrap_or_default();
            let blocks = parse_note_blocks(&md);
            block_count += blocks.len();
            let components = relative_shelf_components(bundle, tb_root);
            let shelf_id = ensure_shelf_cached(&components, shelves, &mut shelf_cache)?;
            flush_leaf(docs, &title, blocks, shelf_id)?;
            tb_only_count += 1;
        }

        let leaf_count = tb_matched_count + realm_fallback_count + tb_only_count;
        let result = ImportResult {
            app: "Craft (Combined)",
            book_id: None,
            leaves: leaf_count,
            entries: 0,
            blocks: block_count,
            skipped,
        };
        let breakdown = CraftCombinedBreakdown {
            matched_textbundle: tb_matched_count,
            realm_fallback: realm_fallback_count,
            textbundle_only: tb_only_count,
        };
        Ok((result, breakdown))
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
        docs: &(dyn LeafRepository + Send + Sync),
        dbs: &(dyn BookRepository + Send + Sync),
        shelves: &(dyn ShelfRepository + Send + Sync),
    ) -> Result<ImportResult, ExtractorError> {
        self.run_detailed(config, docs, dbs, shelves)
            .await
            .map(|(r, _)| r)
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Gets or creates the shelf for `components`, caching results.
fn ensure_shelf_cached(
    components: &[String],
    shelves: &dyn ShelfRepository,
    cache: &mut HashMap<Vec<String>, Uuid>,
) -> Result<Option<Uuid>, ExtractorError> {
    if components.is_empty() {
        return Ok(None);
    }
    let key = components.to_vec();
    if let Some(&id) = cache.get(&key) {
        return Ok(Some(id));
    }
    let parent_id = ensure_shelf_cached(&components[..components.len() - 1], shelves, cache)?;
    let name = &components[components.len() - 1];
    let shelf = shelves
        .create(name, parent_id)
        .map_err(|e| ExtractorError::Parse(format!("shelf creation failed: {e}")))?;
    cache.insert(key, shelf.id);
    Ok(Some(shelf.id))
}

/// Normalizes a title for cross-source matching.
///
/// Steps (in order):
///   1. Trim leading/trailing whitespace.
///   2. Strip leading Markdown heading markers (`# `, `## `, `### `).
///   3. Strip trailing Craft dedup suffix (` (1)`, ` (2)`, …).
///   4. Lowercase.
pub fn normalize(title: &str) -> String {
    let s = title.trim();
    // Strip heading markers that may appear if a heading block was picked as title
    let s = s
        .strip_prefix("### ")
        .or_else(|| s.strip_prefix("## "))
        .or_else(|| s.strip_prefix("# "))
        .unwrap_or(s);
    // Strip Craft dedup suffix " (N)"
    let s = strip_dedup_suffix(s);
    s.to_lowercase()
}

/// Strips a trailing ` (N)` suffix where N is one or more ASCII digits.
fn strip_dedup_suffix(s: &str) -> &str {
    if let Some(open) = s.rfind(" (") {
        let tail = &s[open + 2..];
        let digits = tail.strip_suffix(')').unwrap_or("");
        if !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit()) {
            return &s[..open];
        }
    }
    s
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

    #[test]
    fn normalize_strips_h1() {
        assert_eq!(normalize("# My Note"), "my note");
    }

    #[test]
    fn normalize_strips_h2() {
        assert_eq!(normalize("## My Note"), "my note");
    }

    #[test]
    fn normalize_strips_h3() {
        assert_eq!(normalize("### My Note"), "my note");
    }

    #[test]
    fn normalize_no_heading_untouched() {
        assert_eq!(normalize("#Hashtag"), "#hashtag");
    }

    #[test]
    fn normalize_strips_dedup_suffix() {
        assert_eq!(normalize("My Note (1)"), "my note");
        assert_eq!(normalize("My Note (12)"), "my note");
    }

    #[test]
    fn normalize_dedup_not_stripped_non_digits() {
        assert_eq!(normalize("My Note (abc)"), "my note (abc)");
    }

    #[test]
    fn normalize_dedup_not_stripped_empty_parens() {
        assert_eq!(normalize("My Note ()"), "my note ()");
    }

    #[test]
    fn normalize_heading_and_dedup_combined() {
        assert_eq!(normalize("# Meeting Notes (2)"), "meeting notes");
    }
}
