use crate::application::error::PinkhaError;
use crate::application::unit_of_work::UnitOfWork;
use crate::domain::leaf::{Block, BlockContent, LeafMeta};

/// Case-insensitive search across leaf titles.
pub fn search_leaves(
    uow: &dyn UnitOfWork,
    query: &str,
) -> Result<Vec<LeafMeta>, PinkhaError> {
    let q = query.to_lowercase();
    Ok(uow
        .leaves()
        .list()?
        .into_iter()
        .filter(|m| {
            m.title
                .iter()
                .any(|t| t.content.to_lowercase().contains(&q))
        })
        .collect())
}

/// Case-insensitive full-text search across the block content of all leaves.
///
/// Returns the metadata of leaves that contain at least one matching block.
pub fn search_in_blocks(
    uow: &dyn UnitOfWork,
    query: &str,
) -> Result<Vec<LeafMeta>, PinkhaError> {
    let repo = uow.leaves();
    let q = query.to_lowercase();
    let metas = repo.list()?;
    let mut results = Vec::new();
    for meta in metas {
        let doc = repo.load(meta.id)?;
        if blocks_contain(&doc.blocks, &q) {
            results.push(meta);
        }
    }
    Ok(results)
}

/// Case-insensitive search across book titles.
pub fn search_books(
    uow: &dyn UnitOfWork,
    query: &str,
) -> Result<Vec<crate::domain::book::BookMeta>, PinkhaError> {
    let q = query.to_lowercase();
    Ok(uow
        .books()
        .list_meta()?
        .into_iter()
        .filter(|m| {
            m.title
                .iter()
                .any(|t| t.content.to_lowercase().contains(&q))
        })
        .collect())
}

/// A single hit from a block-content search — the leaf metadata
/// plus a short snippet of the matching block, ready to surface in the
/// UI alongside a Notion-style highlight.
#[derive(Debug, Clone)]
pub struct BlockSearchHit {
    pub doc: LeafMeta,
    /// UUID of the block where the snippet was extracted. Lets the UI
    /// scroll directly to the match when opening the leaf.
    pub block_id: uuid::Uuid,
    pub snippet: String,
}

/// Same scope as [`search_in_blocks`] but additionally extracts a small
/// preview window (~40 chars before the match, ~80 after) so the UI can
/// show context like Notion does.
pub fn search_in_blocks_with_snippets(
    uow: &dyn UnitOfWork,
    query: &str,
) -> Result<Vec<BlockSearchHit>, PinkhaError> {
    let repo = uow.leaves();
    let q = query.to_lowercase();
    let metas = repo.list()?;
    let mut hits = Vec::new();
    for meta in metas {
        let doc = repo.load(meta.id)?;
        let mut matches = Vec::new();
        collect_block_snippets(&doc.blocks, &q, &mut matches);
        for (block_id, snippet) in matches {
            hits.push(BlockSearchHit {
                doc: meta.clone(),
                block_id,
                snippet,
            });
        }
    }
    Ok(hits)
}

/// Walks the block tree depth-first and appends `(block_id, snippet)` for
/// every block whose plain text contains `query`. Used to surface one
/// preview row per match so the user can pick the specific occurrence
/// they meant in a doc that contains the term more than once.
fn collect_block_snippets(blocks: &[Block], query: &str, out: &mut Vec<(uuid::Uuid, String)>) {
    for block in blocks {
        if let Some(text) = block_plain_text(&block.content)
            && let Some(snippet) = extract_snippet(&text, query)
        {
            out.push((block.id, snippet));
        }
        collect_block_snippets(&block.children, query, out);
    }
}

fn block_plain_text(content: &BlockContent) -> Option<String> {
    match content {
        BlockContent::Text(inlines)
        | BlockContent::Heading { text: inlines, .. }
        | BlockContent::Quote { text: inlines, .. }
        | BlockContent::Todo { text: inlines, .. }
        | BlockContent::BulletedListItem(inlines)
        | BlockContent::NumberedListItem(inlines) => Some(
            inlines
                .iter()
                .map(|i| i.content.as_str())
                .collect::<Vec<_>>()
                .join(""),
        ),
        BlockContent::Code { text, .. } => Some(text.clone()),
        _ => None,
    }
}

/// Returns a Unicode-safe window around the first case-insensitive
/// occurrence of `query_lower` in `text`. Adds an ellipsis at each end
/// that was truncated so the user sees the cut explicitly.
fn extract_snippet(text: &str, query_lower: &str) -> Option<String> {
    let lower = text.to_lowercase();
    let byte_idx = lower.find(query_lower)?;
    // Walk chars to find the char index matching `byte_idx`.
    let chars: Vec<char> = text.chars().collect();
    let mut char_idx = 0;
    let mut byte_acc = 0;
    for (i, c) in chars.iter().enumerate() {
        if byte_acc >= byte_idx {
            char_idx = i;
            break;
        }
        byte_acc += c.len_utf8();
        char_idx = i + 1;
    }
    let query_chars = query_lower.chars().count();
    let start = char_idx.saturating_sub(40);
    let end = (char_idx + query_chars + 80).min(chars.len());
    let mut snippet = String::new();
    if start > 0 {
        snippet.push('…');
    }
    snippet.extend(chars[start..end].iter());
    if end < chars.len() {
        snippet.push('…');
    }
    Some(snippet)
}

/// Case-insensitive search across shelf names.
pub fn search_shelves(
    uow: &dyn UnitOfWork,
    query: &str,
) -> Result<Vec<crate::domain::shelf::ShelfMeta>, PinkhaError> {
    let q = query.to_lowercase();
    Ok(uow
        .shelves()
        .list()?
        .into_iter()
        .filter(|m| m.name.to_lowercase().contains(&q))
        .collect())
}

/// Bundle of search results across every library surface: leaf
/// titles, block content (with snippets), book titles and shelf
/// names. Returned by [`super_search`].
#[derive(Debug, Clone)]
pub struct SuperSearchResults {
    pub leaves_by_title: Vec<LeafMeta>,
    /// Block-level hits for leaves that did **not** already match by
    /// title — a doc matching both surfaces once in `leaves_by_title`.
    pub leaves_by_content: Vec<BlockSearchHit>,
    pub books: Vec<crate::domain::book::BookMeta>,
    pub shelves: Vec<crate::domain::shelf::ShelfMeta>,
}

/// Runs every search axis in a single call and deduplicates the leaf
/// axis: a leaf matching by title is excluded from the content hits
/// so it surfaces exactly once in the title section.
pub fn super_search(uow: &dyn UnitOfWork, query: &str) -> Result<SuperSearchResults, PinkhaError> {
    let leaves_by_title = search_leaves(uow, query)?;
    let block_hits = search_in_blocks_with_snippets(uow, query)?;
    let books = search_books(uow, query)?;
    let shelves = search_shelves(uow, query)?;

    let title_ids: std::collections::HashSet<uuid::Uuid> =
        leaves_by_title.iter().map(|m| m.id).collect();
    let leaves_by_content = block_hits
        .into_iter()
        .filter(|h| !title_ids.contains(&h.doc.id))
        .collect();

    Ok(SuperSearchResults {
        leaves_by_title,
        leaves_by_content,
        books,
        shelves,
    })
}

// ── Internal helpers ──────────────────────────────────────────────────────────

fn blocks_contain(blocks: &[Block], query: &str) -> bool {
    blocks.iter().any(|b| block_contains(b, query))
}

fn block_contains(block: &Block, query: &str) -> bool {
    let matches_text = match &block.content {
        BlockContent::Text(inlines)
        | BlockContent::Heading { text: inlines, .. }
        | BlockContent::Quote { text: inlines, .. }
        | BlockContent::Todo { text: inlines, .. }
        | BlockContent::BulletedListItem(inlines)
        | BlockContent::NumberedListItem(inlines) => inlines
            .iter()
            .any(|i| i.content.to_lowercase().contains(query)),
        BlockContent::Code { text, .. } => text.to_lowercase().contains(query),
        _ => false,
    };
    matches_text || blocks_contain(&block.children, query)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::application::error::PinkhaError;
    use crate::domain::leaf::{Block, BlockContent, Leaf, LeafMeta, InlineText};

    use std::collections::HashMap;
    use uuid::Uuid;

    struct MockRepo {
        docs: std::sync::Mutex<HashMap<Uuid, Leaf>>,
    }

    impl MockRepo {
        fn new() -> Self {
            Self {
                docs: std::sync::Mutex::new(HashMap::new()),
            }
        }
    }

    impl crate::application::repository::LeafRepository for MockRepo {
        fn save(&self, doc: &Leaf) -> Result<(), PinkhaError> {
            self.docs.lock().unwrap().insert(doc.id, doc.clone());
            Ok(())
        }
        fn load(&self, id: Uuid) -> Result<Leaf, PinkhaError> {
            self.docs
                .lock()
                .unwrap()
                .get(&id)
                .cloned()
                .ok_or(PinkhaError::NotFound(id))
        }
        fn list(&self) -> Result<Vec<LeafMeta>, PinkhaError> {
            Ok(self
                .docs
                .lock()
                .unwrap()
                .values()
                .map(LeafMeta::from)
                .collect())
        }
        fn delete(&self, id: Uuid) -> Result<(), PinkhaError> {
            self.docs
                .lock()
                .unwrap()
                .remove(&id)
                .map(|_| ())
                .ok_or(PinkhaError::NotFound(id))
        }
        fn move_to_shelf(
            &self,
            _leaf_id: Uuid,
            _shelf_id: Option<Uuid>,
        ) -> Result<(), PinkhaError> {
            Ok(())
        }
        fn list_by_shelf(
            &self,
            _shelf_id: Option<Uuid>,
        ) -> Result<Vec<LeafMeta>, PinkhaError> {
            self.list()
        }
    }

    use crate::application::repository::LeafRepository;
    use crate::application::unit_of_work::test_support::MockUnitOfWork;

    fn inline(s: &str) -> Vec<InlineText> {
        vec![InlineText {
            content: s.to_string(),
            styles: vec![],
        }]
    }

    fn text_block(s: &str) -> Block {
        Block::new(BlockContent::Text(inline(s)))
    }

    fn leaf_with_blocks(title: &str, blocks: Vec<Block>) -> Leaf {
        let mut doc = Leaf::new(inline(title));
        doc.blocks = blocks;
        doc
    }

    fn leaf_uow(repo: &MockRepo) -> MockUnitOfWork<'_> {
        MockUnitOfWork::with_leaves(repo)
    }

    #[test]
    fn test_search_in_blocks_trouve() {
        let repo = MockRepo::new();
        let doc = leaf_with_blocks("Doc", vec![text_block("Rust est génial")]);
        repo.save(&doc).unwrap();

        let results = search_in_blocks(&leaf_uow(&repo), "rust").unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].id, doc.id);
    }

    #[test]
    fn test_search_in_blocks_pas_de_resultat() {
        let repo = MockRepo::new();
        let doc = leaf_with_blocks("Doc", vec![text_block("Bonjour monde")]);
        repo.save(&doc).unwrap();

        let results = search_in_blocks(&leaf_uow(&repo), "flutter").unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_search_in_blocks_enfants() {
        let repo = MockRepo::new();
        let mut parent = text_block("parent");
        parent
            .children
            .push(text_block("texte caché en profondeur"));
        let doc = leaf_with_blocks("Doc", vec![parent]);
        repo.save(&doc).unwrap();

        let results = search_in_blocks(&leaf_uow(&repo), "profondeur").unwrap();
        assert_eq!(results.len(), 1);
    }

    // ── Snippet variant ──────────────────────────────────────────────────

    #[test]
    fn snippets_returns_one_hit_per_matching_block() {
        let repo = MockRepo::new();
        let doc = leaf_with_blocks(
            "Doc",
            vec![
                text_block("Rust is great"),
                text_block("Nothing here"),
                text_block("More Rust love"),
            ],
        );
        repo.save(&doc).unwrap();

        let hits = search_in_blocks_with_snippets(&leaf_uow(&repo), "rust").unwrap();
        // Two block-level hits surface for the same doc, each carrying
        // its own block_id so the UI can jump straight to the line.
        assert_eq!(hits.len(), 2);
        let block_ids: std::collections::HashSet<_> = hits.iter().map(|h| h.block_id).collect();
        assert_eq!(block_ids.len(), 2);
        for hit in &hits {
            assert_eq!(hit.doc.id, doc.id);
            assert!(hit.snippet.to_lowercase().contains("rust"));
        }
    }

    #[test]
    fn snippets_walk_into_children() {
        let repo = MockRepo::new();
        let mut parent = text_block("Parent line that does not match");
        let child = text_block("the keyword lives here");
        let child_id = child.id;
        parent.children.push(child);
        let doc = leaf_with_blocks("Doc", vec![parent]);
        repo.save(&doc).unwrap();

        let hits = search_in_blocks_with_snippets(&leaf_uow(&repo), "keyword").unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].block_id, child_id);
    }

    #[test]
    fn snippets_skip_leaves_without_match() {
        let repo = MockRepo::new();
        let doc = leaf_with_blocks("Doc", vec![text_block("nothing relevant")]);
        repo.save(&doc).unwrap();
        let hits = search_in_blocks_with_snippets(&leaf_uow(&repo), "missing").unwrap();
        assert!(hits.is_empty());
    }

    #[test]
    fn extract_snippet_adds_ellipsis_when_truncated() {
        // 200-char text — match at offset 100 forces both ends to be
        // truncated, so both ellipses should appear.
        let prefix: String = "a".repeat(100);
        let suffix: String = "b".repeat(100);
        let text = format!("{prefix}NEEDLE{suffix}");
        let snippet = extract_snippet(&text, "needle").expect("match expected");
        assert!(snippet.starts_with('…'));
        assert!(snippet.ends_with('…'));
        assert!(snippet.to_lowercase().contains("needle"));
    }

    #[test]
    fn extract_snippet_returns_none_when_no_match() {
        assert!(extract_snippet("hello world", "missing").is_none());
    }

    #[test]
    fn extract_snippet_no_ellipsis_when_short_text() {
        // Short enough to fit entirely in the 40-before / 80-after window.
        let snippet = extract_snippet("Rust is great", "rust").unwrap();
        assert!(!snippet.starts_with('…'));
        assert!(!snippet.ends_with('…'));
    }

    #[test]
    fn block_plain_text_handles_every_textual_variant() {
        use crate::domain::leaf::BlockContent;
        let text_inline = inline("plain text");
        let cases: Vec<(BlockContent, &str)> = vec![
            (BlockContent::Text(text_inline.clone()), "plain text"),
            (
                BlockContent::Heading {
                    level: 1,
                    text: text_inline.clone(),
                },
                "plain text",
            ),
            (
                BlockContent::Quote {
                    icon: None,
                    text: text_inline.clone(),
                },
                "plain text",
            ),
            (
                BlockContent::Todo {
                    done: false,
                    text: text_inline.clone(),
                },
                "plain text",
            ),
            (
                BlockContent::BulletedListItem(text_inline.clone()),
                "plain text",
            ),
            (
                BlockContent::NumberedListItem(text_inline.clone()),
                "plain text",
            ),
            (
                BlockContent::Code {
                    text: "fn main() {}".to_string(),
                    language: String::new(),
                },
                "fn main() {}",
            ),
        ];
        for (content, expected) in cases {
            assert_eq!(block_plain_text(&content).as_deref(), Some(expected));
        }
        // Non-textual variants return None.
        assert!(block_plain_text(&BlockContent::Divider).is_none());
    }
}
