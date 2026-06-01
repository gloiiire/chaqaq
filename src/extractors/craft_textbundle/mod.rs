// ── Craft TextBundle extractor ────────────────────────────────────────────────
//
// Reads a folder of `.textbundle` packages exported from Craft ("Export All").
//
// Pipeline:
//   → walk root_dir recursively for *.textbundle directories
//   → title   = filename stem (e.g. "My Note.textbundle" → "My Note")
//   → content = text.markdown parsed by the Bear markdown parser (same dialect)
//   → persist one pinkha Document per textbundle

use std::path::{Path, PathBuf};

use crate::application::database_repository::DatabaseRepository;
use crate::application::repository::DocumentRepository;
use crate::application::use_cases;
use crate::domain::document::BlockContent;
use crate::extractors::bear::mapper::parse_note_blocks;
use crate::extractors::traits::Extractor;
use crate::extractors::{ExtractorError, ImportResult};

// ── Config ────────────────────────────────────────────────────────────────────

pub struct CraftTextBundleConfig {
    /// Path to the root folder that contains `.textbundle` packages
    /// (may be nested in sub-folders).
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
        docs: &(dyn DocumentRepository + Send + Sync),
        _dbs: &(dyn DatabaseRepository + Send + Sync),
    ) -> Result<ImportResult, ExtractorError> {
        let root = Path::new(&config.root_dir);
        let bundles = find_textbundles(root);

        let mut doc_count = 0usize;
        let mut block_count = 0usize;
        let skipped = 0usize;

        for bundle_path in &bundles {
            let title = textbundle_title(bundle_path);
            let md_path = bundle_path.join("text.markdown");
            let markdown = std::fs::read_to_string(&md_path).unwrap_or_default();
            let blocks = parse_note_blocks(&markdown);
            block_count += blocks.len();
            flush_document(docs, &title, blocks)?;
            doc_count += 1;
        }

        Ok(ImportResult {
            app: "Craft (TextBundle)",
            database_id: None,
            documents: doc_count,
            entries: 0,
            blocks: block_count,
            skipped,
        })
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Walks `dir` recursively and returns paths to every `.textbundle` package found.
/// Does not recurse into `.textbundle` directories themselves.
fn find_textbundles(dir: &Path) -> Vec<PathBuf> {
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

/// Extracts the document title from a `.textbundle` path (the filename stem).
fn textbundle_title(path: &Path) -> String {
    path.file_stem()
        .and_then(|s| s.to_str())
        .filter(|s| !s.is_empty())
        .unwrap_or("Untitled")
        .to_string()
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
        let p = Path::new("/some/folder/My Note.textbundle");
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
}
