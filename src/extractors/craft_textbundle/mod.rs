// ── Craft TextBundle extractor ────────────────────────────────────────────────
//
// Reads a shelf of `.textbundle` packages exported from Craft ("Export All").
//
// Pipeline:
//   → walk root_dir recursively for *.textbundle directories
//   → title   = filename stem (e.g. "My Note.textbundle" → "My Note")
//   → content = text.markdown parsed by the Bear markdown parser (same dialect)
//   → persist one pinkha Leaf per textbundle, mirroring subdirectory → shelf

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::application::book_repository::BookRepository;
use crate::application::repository::LeafRepository;
use crate::application::shelf_repository::ShelfRepository;
use crate::extractors::bear::mapper::parse_note_blocks;
use crate::extractors::craft::flush_leaf;
use crate::extractors::traits::Extractor;
use crate::extractors::{ExtractorError, ImportResult};
use uuid::Uuid;

// ── Config ────────────────────────────────────────────────────────────────────

pub struct CraftTextBundleConfig {
    /// Path to the root shelf that contains `.textbundle` packages
    /// (may be nested in sub-shelves).
    pub root_dir: String,
}

// ── Extractor ─────────────────────────────────────────────────────────────────

pub struct CraftTextBundleExtractor;

impl CraftTextBundleExtractor {
    pub fn new() -> Self {
        Self
    }
}

impl Default for CraftTextBundleExtractor {
    fn default() -> Self {
        Self::new()
    }
}

impl Extractor for CraftTextBundleExtractor {
    type Config = CraftTextBundleConfig;

    fn app_name(&self) -> &'static str {
        "Craft (TextBundle)"
    }

    async fn run(
        &self,
        config: CraftTextBundleConfig,
        docs: &(dyn LeafRepository + Send + Sync),
        _books: &(dyn BookRepository + Send + Sync),
        shelves: &(dyn ShelfRepository + Send + Sync),
    ) -> Result<ImportResult, ExtractorError> {
        let root = Path::new(&config.root_dir);
        if !root.exists() {
            return Err(ExtractorError::Parse(format!(
                "textbundle root does not exist: {}",
                config.root_dir
            )));
        }
        if !root.is_dir() {
            return Err(ExtractorError::Parse(format!(
                "textbundle root is not a directory: {}",
                config.root_dir
            )));
        }
        let bundles = find_textbundles(root);

        let mut leaf_count = 0usize;
        let mut block_count = 0usize;
        let mut shelf_cache: HashMap<Vec<String>, Uuid> = HashMap::new();

        for bundle_path in &bundles {
            let title = textbundle_title(bundle_path);
            let md_path = bundle_path.join("text.markdown");
            let markdown = std::fs::read_to_string(&md_path).unwrap_or_default();
            let parsed_blocks = parse_note_blocks(&markdown);
            block_count += parsed_blocks.len();

            let components = relative_shelf_components(bundle_path, root);
            let shelf_id = ensure_shelf(&components, shelves, &mut shelf_cache)
                .map_err(|e| ExtractorError::Parse(format!("shelf creation failed: {e}")))?;

            flush_leaf(docs, &title, parsed_blocks, shelf_id)?;
            leaf_count += 1;
        }

        Ok(ImportResult {
            app: "Craft (TextBundle)",
            book_id: None,
            leaves: leaf_count,
            entries: 0,
            blocks: block_count,
            skipped: 0,
        })
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Walks `dir` recursively and returns paths to every `.textbundle` package found.
/// Does not recurse into `.textbundle` directories themselves.
pub fn find_textbundles(dir: &Path) -> Vec<PathBuf> {
    let mut result = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return result;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        if path.extension().and_then(|e| e.to_str()) == Some("textbundle") {
            result.push(path);
        } else {
            result.extend(find_textbundles(&path));
        }
    }
    result
}

/// Extracts the leaf title from a `.textbundle` path (the filename stem).
pub fn textbundle_title(path: &Path) -> String {
    path.file_stem()
        .and_then(|s| s.to_str())
        .filter(|s| !s.is_empty())
        .unwrap_or("Untitled")
        .to_string()
}

/// Returns the shelf path components for a bundle relative to the export root.
///
/// e.g. `/root/SpaceA/SubShelf/Note.textbundle` with root `/root`
/// → `["SpaceA", "SubShelf"]`
pub fn relative_shelf_components(bundle_path: &Path, root: &Path) -> Vec<String> {
    let rel = bundle_path.strip_prefix(root).unwrap_or(bundle_path);
    let parent = rel.parent().unwrap_or(Path::new(""));
    parent
        .components()
        .filter_map(|c| c.as_os_str().to_str())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .collect()
}

/// Gets or creates the shelf for `components`, returning its UUID.
///
/// Parents are created recursively, deepest last. Results are cached so each
/// unique path is created only once per import run.
fn ensure_shelf(
    components: &[String],
    shelves: &dyn ShelfRepository,
    cache: &mut HashMap<Vec<String>, Uuid>,
) -> Result<Option<Uuid>, crate::application::error::PinkhaError> {
    if components.is_empty() {
        return Ok(None);
    }
    let key = components.to_vec();
    if let Some(&id) = cache.get(&key) {
        return Ok(Some(id));
    }
    let parent_id = ensure_shelf(&components[..components.len() - 1], shelves, cache)?;
    let name = &components[components.len() - 1];
    let shelf = shelves.create(name, parent_id)?;
    cache.insert(key, shelf.id);
    Ok(Some(shelf.id))
}

// ── Unit tests ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn tmp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("pinkha_tb_test_{name}"));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn make_bundle(root: &Path, name: &str, markdown: &str) {
        let bundle = root.join(format!("{name}.textbundle"));
        fs::create_dir_all(&bundle).unwrap();
        fs::write(bundle.join("text.markdown"), markdown).unwrap();
        fs::write(bundle.join("info.json"), r#"{"version":2}"#).unwrap();
    }

    #[test]
    fn find_textbundles_flat() {
        let dir = tmp_dir("flat");
        make_bundle(&dir, "Note A", "# Note A\nHello");
        make_bundle(&dir, "Note B", "# Note B\nWorld");
        let found = find_textbundles(&dir);
        assert_eq!(found.len(), 2);
    }

    #[test]
    fn find_textbundles_nested() {
        let dir = tmp_dir("nested");
        let sub = dir.join("Learning").join("Rust");
        fs::create_dir_all(&sub).unwrap();
        make_bundle(&sub, "Ownership", "# Ownership\nContent");
        let found = find_textbundles(&dir);
        assert_eq!(found.len(), 1);
    }

    #[test]
    fn find_textbundles_does_not_recurse_into_bundle() {
        let dir = tmp_dir("no_recurse");
        let outer = dir.join("Outer.textbundle");
        fs::create_dir_all(&outer).unwrap();
        fs::write(outer.join("text.markdown"), "# Outer\n").unwrap();
        let inner = outer.join("Inner.textbundle");
        fs::create_dir_all(&inner).unwrap();
        fs::write(inner.join("text.markdown"), "# Inner\n").unwrap();
        let found = find_textbundles(&dir);
        assert_eq!(found.len(), 1);
        assert!(found[0].ends_with("Outer.textbundle"));
    }

    #[test]
    fn textbundle_title_from_path() {
        let p = Path::new("/some/shelf/My Note.textbundle");
        assert_eq!(textbundle_title(p), "My Note");
    }

    #[test]
    fn textbundle_title_emoji() {
        let p = Path::new("/root/Courses 🏡.textbundle");
        assert_eq!(textbundle_title(p), "Courses 🏡");
    }

    #[test]
    fn textbundle_title_no_parent() {
        let p = Path::new("Simple.textbundle");
        assert_eq!(textbundle_title(p), "Simple");
    }

    #[test]
    fn relative_shelf_components_root_level() {
        let root = Path::new("/export");
        let bundle = Path::new("/export/Note.textbundle");
        let components = relative_shelf_components(bundle, root);
        assert!(components.is_empty());
    }

    #[test]
    fn relative_shelf_components_one_level() {
        let root = Path::new("/export");
        let bundle = Path::new("/export/SpaceA/Note.textbundle");
        let components = relative_shelf_components(bundle, root);
        assert_eq!(components, vec!["SpaceA"]);
    }

    #[test]
    fn relative_shelf_components_nested() {
        let root = Path::new("/export");
        let bundle = Path::new("/export/SpaceA/SubShelf/Note.textbundle");
        let components = relative_shelf_components(bundle, root);
        assert_eq!(components, vec!["SpaceA", "SubShelf"]);
    }
}
