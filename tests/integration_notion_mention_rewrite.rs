//! Integration test for Notion mention rewriting at import time.
//!
//! The full Notion import is async + hits the real API, so we exercise the
//! pure post-pass step (`rewrite_notion_mentions`) directly here: seed a
//! document containing a Notion-style `[label](https://www.notion.so/...)`
//! link, run the rewriter with a Notion→Pinkha map, and verify the link now
//! points at the matching `pinkha://doc/…`.

use pinkha::application::use_cases::create_document;
use pinkha::domain::document::{Block, BlockContent, InlineStyle, InlineText};
use pinkha::extractors::notion::{normalize_notion_id, rewrite_notion_mentions};
use pinkha::infrastructure::json_store::JsonStore;
use std::collections::HashMap;
use uuid::Uuid;

fn store_temp() -> JsonStore {
    let dir = std::env::temp_dir().join(format!("pinkha_notion_rewrite_{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    JsonStore::new(dir)
}

fn span_with_link(text: &str, url: &str) -> InlineText {
    InlineText {
        content: text.into(),
        styles: vec![InlineStyle::Link(url.into())],
    }
}

#[test]
fn rewrite_replaces_notion_url_with_pinkha_doc_link() {
    let store = store_temp();

    // The "target" page that the link points to — already imported.
    let target_doc = create_document(&store, "Target page").unwrap();

    // The "source" page that links to the target.
    let mut source_doc = create_document(&store, "Source page").unwrap();
    let notion_target_id = "abc123def456abc123def456abc123de"; // 32 hex
    let notion_url = format!("https://www.notion.so/My-Workspace/Target-page-{notion_target_id}");
    source_doc.blocks.push(Block::new(BlockContent::Text(vec![
        InlineText {
            content: "See ".into(),
            styles: vec![],
        },
        span_with_link("Target page", &notion_url),
    ])));
    use pinkha::application::repository::DocumentRepository;
    store.save(&source_doc).unwrap();

    // Build the import map (Notion id → Pinkha doc UUID).
    let mut map: HashMap<String, Uuid> = HashMap::new();
    map.insert(normalize_notion_id(notion_target_id), target_doc.id);

    // Run the rewriter on the source document.
    rewrite_notion_mentions(&store, source_doc.id, &map).unwrap();

    // The link URL should now point at the target Pinkha doc.
    let reloaded = pinkha::application::use_cases::get_document(&store, source_doc.id).unwrap();
    if let BlockContent::Text(spans) = &reloaded.blocks[0].content {
        let link_span = &spans[1];
        let Some(InlineStyle::Link(url)) = link_span.styles.first() else {
            panic!("expected link style on span, got {:?}", link_span.styles);
        };
        assert_eq!(url, &format!("pinkha://doc/{}", target_doc.id));
    } else {
        panic!("expected Text block");
    }
}

#[test]
fn rewrite_leaves_unknown_links_alone() {
    let store = store_temp();
    let mut doc = create_document(&store, "Page").unwrap();
    let foreign_url = "https://example.com/article";
    doc.blocks
        .push(Block::new(BlockContent::Text(vec![span_with_link(
            "Read more",
            foreign_url,
        )])));
    use pinkha::application::repository::DocumentRepository;
    store.save(&doc).unwrap();

    rewrite_notion_mentions(&store, doc.id, &HashMap::new()).unwrap();

    let reloaded = pinkha::application::use_cases::get_document(&store, doc.id).unwrap();
    if let BlockContent::Text(spans) = &reloaded.blocks[0].content {
        if let Some(InlineStyle::Link(url)) = spans[0].styles.first() {
            assert_eq!(url, foreign_url);
        } else {
            panic!("link style missing");
        }
    }
}
