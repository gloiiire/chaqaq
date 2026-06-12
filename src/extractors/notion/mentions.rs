//! 2-pass Notion mention rewriting: after the import builds a
//! `NotionPageId -> PinkhaDocId` map, every imported document is revisited
//! and its `notion.so` links are rewritten to `pinkha://doc/{uuid}` so
//! internal mentions point at the imported notes instead of Notion.

use std::collections::HashMap;

use uuid::Uuid;

use crate::application::repository::DocumentRepository;
use crate::domain::document::{Block, BlockContent, InlineText};
use crate::extractors::ExtractorError;

// ── Mention rewriting ─────────────────────────────────────────────────────────

/// Normalises a Notion ID (page or block) for use as a `HashMap` key.
///
/// Notion sometimes returns IDs with dashes (`1234abcd-...-...`), sometimes
/// without (in URLs). Strip the dashes and lower-case so equivalent IDs hash
/// to the same bucket.
pub fn normalize_notion_id(raw: &str) -> String {
    raw.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .flat_map(|c| c.to_lowercase())
        .collect()
}

/// Walks a Pinkha document loaded from `docs` and rewrites every inline link
/// whose URL embeds a Notion page ID we just imported. The new URL points to
/// the corresponding Pinkha document via the `pinkha://doc/{uuid}` scheme.
///
/// Persists the document only when at least one link was rewritten — keeps
/// I/O minimal for documents that don't cross-reference anything.
pub fn rewrite_notion_mentions(
    docs: &(dyn DocumentRepository + Send + Sync),
    doc_id: Uuid,
    notion_to_pinkha: &HashMap<String, Uuid>,
) -> Result<(), ExtractorError> {
    rewrite_notion_mentions_logged(docs, doc_id, notion_to_pinkha, None)
}

/// Logging variant — same behaviour as `rewrite_notion_mentions` but
/// appends a one-line summary to `<covers_dir>/notion-debug.log` so the
/// app can later report on link rewrites and Page-block promotions.
pub fn rewrite_notion_mentions_logged(
    docs: &(dyn DocumentRepository + Send + Sync),
    doc_id: Uuid,
    notion_to_pinkha: &HashMap<String, Uuid>,
    covers_dir: Option<&str>,
) -> Result<(), ExtractorError> {
    use crate::application::error::PinkhaError;
    let mut doc = docs.load(doc_id).map_err(|e: PinkhaError| match e {
        PinkhaError::NotFound(_) => ExtractorError::Parse(format!("doc {doc_id} not found")),
        other => ExtractorError::Parse(other.to_string()),
    })?;
    let mut rewrote = false;
    for block in doc.blocks.iter_mut() {
        rewrite_block_links(block, notion_to_pinkha, &mut rewrote);
    }
    // Second sub-pass : promote paragraphs that contain *only* a single
    // `pinkha://doc/{uuid}` link to a first-class `Page` block. Notion
    // never returns these references as `child_page` blocks (they're
    // page mentions inside paragraphs), so without this promotion the
    // imported docs render their sub-page references as inline links
    // instead of the chunky tappable rows users expect.
    let mut promoted_count = 0;
    promote_page_link_paragraphs(&mut doc.blocks, &mut promoted_count);
    if let Some(dir) = covers_dir {
        use std::io::Write;
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(format!("{dir}/notion-debug.log"))
        {
            let _ = writeln!(
                f,
                "[rewrite] doc={doc_id} links_rewritten={rewrote} promotions={promoted_count}"
            );
            // Also dump non-promoted paragraphs that carry a pinkha link
            // so we can iterate on the promotion criterion. We re-walk
            // the just-updated tree; a no-op when everything promoted.
            dump_unpromoted_links(&doc.blocks, dir);
        }
    }
    if rewrote || promoted_count > 0 {
        docs.save(&doc)
            .map_err(|e| ExtractorError::Parse(e.to_string()))?;
    }
    Ok(())
}

/// Recursively walks the block tree and replaces paragraphs whose entire
/// content is a single `pinkha://doc/{uuid}` link with the dedicated
/// `BlockContent::Page { id }` block. Sets `*promoted = true` when at
/// least one block changes so the caller can skip a no-op save.
/// Writes the raw span shape of every paragraph that survived rewrite
/// but failed promotion. Picked up by the next iteration so we can
/// learn what the Notion data actually looks like.
fn dump_unpromoted_links(blocks: &[Block], dir: &str) {
    let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(format!("{dir}/notion-debug.log"))
    else {
        return;
    };
    walk_dump(blocks, &mut f);
}

fn walk_dump<W: std::io::Write>(blocks: &[Block], f: &mut W) {
    for block in blocks {
        if let BlockContent::Text(spans) = &block.content {
            let has_pinkha_link = spans.iter().any(|s| {
                s.styles.iter().any(|st| {
                    matches!(st, chaqaq::InlineStyle::Link(url) if url.starts_with("pinkha://doc/"))
                })
            });
            if has_pinkha_link {
                let _ = writeln!(
                    f,
                    "[promote skip] {} spans: {}",
                    spans.len(),
                    spans
                        .iter()
                        .map(|s| {
                            let link = s.styles.iter().find_map(|st| {
                                if let chaqaq::InlineStyle::Link(u) = st {
                                    Some(u.as_str())
                                } else {
                                    None
                                }
                            });
                            format!("({:?}, link={:?})", s.content, link)
                        })
                        .collect::<Vec<_>>()
                        .join(" | ")
                );
            }
        }
        walk_dump(&block.children, f);
    }
}

fn promote_page_link_paragraphs(
    blocks: &mut [crate::domain::document::Block],
    promoted: &mut usize,
) {
    for block in blocks.iter_mut() {
        if let BlockContent::Text(spans) = &block.content
            && let Some(child_id) = sole_pinkha_doc_link(spans)
        {
            block.content = BlockContent::Page { id: child_id };
            *promoted += 1;
        }
        promote_page_link_paragraphs(&mut block.children, promoted);
    }
}

/// Returns the doc UUID if `spans` collectively encode a single
/// `pinkha://doc/{uuid}` link — the signature of a Notion page mention
/// sitting alone on its line. Whitespace-only runs (Notion likes to
/// pad mentions with empty/blank runs) are ignored. Any non-link
/// substantive text, or multiple distinct link targets, bail out so
/// "see also: [link]" or "[a] and [b]" stay as inline paragraphs.
fn sole_pinkha_doc_link(spans: &[chaqaq::InlineText]) -> Option<Uuid> {
    let mut target: Option<Uuid> = None;
    for run in spans {
        let mut run_link: Option<&str> = None;
        for style in &run.styles {
            if let chaqaq::InlineStyle::Link(url) = style {
                if run_link.is_some() {
                    return None; // more than one link in the same run
                }
                run_link = Some(url.as_str());
            }
        }
        match run_link {
            Some(url) => {
                let suffix = url.strip_prefix("pinkha://doc/")?;
                let id = Uuid::parse_str(suffix).ok()?;
                match target {
                    Some(existing) if existing != id => return None,
                    _ => target = Some(id),
                }
            }
            None => {
                // No link on this run — only accept it as filler if it's
                // pure whitespace; any real text means the paragraph is
                // mixed content and we leave it alone.
                if !run.content.trim().is_empty() {
                    return None;
                }
            }
        }
    }
    target
}

/// Recursively rewrites links in `block` and its descendants. Sets
/// `*rewrote = true` if any link was changed so the caller can skip the
/// `save` when nothing changed.
fn rewrite_block_links(
    block: &mut crate::domain::document::Block,
    notion_to_pinkha: &HashMap<String, Uuid>,
    rewrote: &mut bool,
) {
    rewrite_inlines_in_content(&mut block.content, notion_to_pinkha, rewrote);
    for child in block.children.iter_mut() {
        rewrite_block_links(child, notion_to_pinkha, rewrote);
    }
}

/// Walks the inline-bearing variants of `BlockContent` and rewrites their
/// link styles. Variants without inline text (`Divider`, `Breadcrumb`,
/// `Database`, `Code`) are no-ops.
fn rewrite_inlines_in_content(
    content: &mut crate::domain::document::BlockContent,
    notion_to_pinkha: &HashMap<String, Uuid>,
    rewrote: &mut bool,
) {
    let inlines: Option<&mut Vec<InlineText>> = match content {
        BlockContent::Text(t) => Some(t),
        BlockContent::Heading { text, .. } => Some(text),
        BlockContent::Quote { text, .. } => Some(text),
        BlockContent::Todo { text, .. } => Some(text),
        BlockContent::BulletedListItem(t) => Some(t),
        BlockContent::NumberedListItem(t) => Some(t),
        BlockContent::Divider
        | BlockContent::Breadcrumb
        | BlockContent::Database { .. }
        | BlockContent::Code { .. }
        | BlockContent::Page { .. }
        | BlockContent::Embed { .. } => None,
    };
    if let Some(spans) = inlines {
        for span in spans.iter_mut() {
            for style in span.styles.iter_mut() {
                if let chaqaq::InlineStyle::Link(url) = style
                    && let Some(new_url) = rewrite_url(url, notion_to_pinkha)
                {
                    *url = new_url;
                    *rewrote = true;
                }
            }
        }
    }
}

/// Returns `Some(new_url)` if `url` contains a known Notion page ID; `None`
/// otherwise. The pinkha scheme uses dashed UUIDs for human readability when
/// debugging logs — strict format isn't important since only the app parses
/// these URLs.
fn rewrite_url(url: &str, notion_to_pinkha: &HashMap<String, Uuid>) -> Option<String> {
    let normalized = normalize_notion_id(url);
    // A 32-hex page ID is buried somewhere in the URL — scan for one of our
    // known IDs as a substring. Linear in the map size, fine for typical
    // imports (~hundreds of pages).
    for (notion_id, pinkha_id) in notion_to_pinkha {
        if normalized.contains(notion_id) {
            return Some(format!("pinkha://doc/{pinkha_id}"));
        }
    }
    None
}
#[cfg(test)]
mod mention_tests {
    use super::*;
    use std::collections::HashMap;

    #[test]
    fn normalize_strips_dashes_and_lowercases() {
        assert_eq!(
            normalize_notion_id("1234ABCD-EF56-7890-ABCD-EF1234567890"),
            "1234abcdef567890abcdef1234567890"
        );
        // Already-normalised IDs pass through unchanged.
        assert_eq!(
            normalize_notion_id("abc123def456abc123def456abc123de"),
            "abc123def456abc123def456abc123de"
        );
    }

    #[test]
    fn rewrite_url_matches_known_page_id() {
        let notion_id = "abc123def456abc123def456abc123de".to_string();
        let pinkha_id = Uuid::new_v4();
        let mut map = HashMap::new();
        map.insert(notion_id.clone(), pinkha_id);

        // Standard Notion page URL with dashes — must still match after
        // normalisation.
        let url = "https://www.notion.so/My-Page-abc123def456abc123def456abc123de";
        let rewritten = rewrite_url(url, &map).expect("expected rewrite");
        assert_eq!(rewritten, format!("pinkha://doc/{pinkha_id}"));
    }

    #[test]
    fn rewrite_url_returns_none_for_unknown_ids() {
        let map: HashMap<String, Uuid> = HashMap::new();
        let url = "https://www.notion.so/Some-Page-abc123def456abc123def456abc123de";
        assert!(rewrite_url(url, &map).is_none());
        // Non-Notion URLs aren't touched either.
        assert!(rewrite_url("https://example.com", &map).is_none());
    }
}
