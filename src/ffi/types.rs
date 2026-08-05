//! Dictionary types crossing the FFI boundary and their converters.

use crate::domain::book::BookMeta;
use crate::domain::leaf::LeafMeta;
use crate::domain::shelf::ShelfMeta;

// ── Dictionary types ──────────────────────────────────────────────────────────

/// Lightweight leaf metadata passed across the FFI boundary.
///
/// Carries pre-computed plain-text and JSON representations of the title so
/// that Swift does not need to decode the full leaf to display a list item.
#[derive(Debug, Clone, serde::Serialize)]
pub struct LeafMetaFfi {
    /// UUID string of the leaf.
    pub id: String,
    /// Concatenated plain-text title (all inline spans joined).
    pub title_plain: String,
    /// JSON-encoded `Vec<InlineText>` title (for rich-text rendering).
    pub title_json: String,
    /// Optional cover emoji or image identifier.
    pub cover: Option<String>,
    /// RFC 3339 timestamp of the last update.
    pub updated_at: String,
    /// RFC 3339 timestamp of creation.
    pub created_at: String,
    /// User-editable publish timestamp. Defaults to `created_at` on
    /// fresh docs ; empty string on legacy rows is treated as "follow
    /// `created_at`" by the home view's sort path.
    pub published_at: String,
    /// UUID of the shelf this leaf belongs to, or `None` for root.
    pub shelf_id: Option<String>,
    /// UUID of the parent leaf (Notion-style page-in-page), or `None`
    /// when this is a root page.
    pub parent_leaf_id: Option<String>,
    /// Optional page icon — emoji or filename. Mirrors `Leaf.icon`.
    pub icon: Option<String>,
    /// RFC 3339 timestamp the user pinned this leaf, or `None` when
    /// not pinned. Drives the PINNED section in the home view.
    pub pinned_at: Option<String>,
    /// Manual sort index — `None` falls back to the natural order
    /// (creation date for "All", `pinned_at` desc for "Pinned").
    /// Set via `set_leaves_manual_order` after a drag-and-drop reorder.
    pub manual_order: Option<i32>,
}

/// Lightweight shelf metadata passed across the FFI boundary.
#[derive(Debug, Clone, serde::Serialize)]
pub struct ShelfMetaFfi {
    /// UUID string of the shelf.
    pub id: String,
    /// Display name.
    pub name: String,
    /// UUID of the parent shelf, or `None` for a top-level shelf.
    pub parent_id: Option<String>,
    /// RFC 3339 creation timestamp.
    pub created_at: String,
    /// RFC 3339 last-update timestamp.
    pub updated_at: String,
    /// Optional emoji icon.
    pub icon: Option<String>,
    /// Manual sort index ; `None` means the shelf is rendered in the
    /// section's default order (alphabetical when sorted by name,
    /// chronological when sorted by date).
    pub manual_order: Option<i32>,
}

/// Summary of a completed import operation, returned to Swift.
#[derive(Debug, Clone, serde::Serialize)]
pub struct ImportResultFfi {
    /// Human-readable name of the source application (e.g. `"Notion"`, `"Bear"`).
    pub app: String,
    /// UUID string of the Pinkha book created by this import, or empty if
    /// the source had no book structure (plain notes only).
    pub book_id: String,
    /// Number of Pinkha leaves created.
    pub leaves: u32,
    /// Number of book entries created.
    pub entries: u32,
    /// Number of blocks added across all leaves.
    pub blocks: u32,
    /// Number of source items skipped (unsupported block type, etc.).
    pub skipped: u32,
    /// Combined importer only: pages imported via textbundle content (0 otherwise).
    pub matched_textbundle: u32,
    /// Combined importer only: realm pages with no matching textbundle (0 otherwise).
    pub realm_fallback: u32,
    /// Combined importer only: textbundles with no matching realm page (0 otherwise).
    pub textbundle_only: u32,
}

/// Lightweight Notion book summary returned by `list_notion_databases`.
/// Carries just enough for the picker UI to render a row (title + icon) and
/// kick off an import.
#[derive(Debug, Clone)]
pub struct NotionDatabaseSummaryFfi {
    /// 32-char hex ID. Pass to [`import_from_notion`] as `book_id`.
    pub id: String,
    /// Plain-text title concatenated from Notion's rich-text title runs.
    pub title: String,
    /// Optional emoji icon. Image icons aren't surfaced — the picker uses a
    /// generic book icon when this is empty.
    pub icon_emoji: Option<String>,
    /// ISO 8601 last-edited timestamp from Notion. Already sorted recent-
    /// first by the Rust list call.
    pub last_edited: String,
}

/// Standalone Notion page summary returned by `list_notion_pages`. Same
/// shape as the database summary — separate type so the UDL can model
/// the two list endpoints with distinct sequences.
#[derive(Debug, Clone)]
pub struct NotionPageSummaryFfi {
    pub id: String,
    pub title: String,
    pub icon_emoji: Option<String>,
    pub last_edited: String,
}

/// One match from a block-content search. Carries the leaf metadata
/// plus a short snippet of the matching block so the UI can preview
/// where the hit occurs, Notion-style.
#[derive(Debug, Clone, serde::Serialize)]
pub struct BlockSearchHitFfi {
    pub doc: LeafMetaFfi,
    /// UUID string of the matching block — lets Swift scroll directly
    /// to it when opening the leaf from a search result.
    pub block_id: String,
    pub snippet: String,
}

/// Lightweight book metadata passed across the FFI boundary.
#[derive(Debug, Clone, serde::Serialize)]
pub struct BookMetaFfi {
    /// UUID string of the book.
    pub id: String,
    /// Concatenated plain-text title.
    pub title_plain: String,
    /// JSON-encoded `Vec<InlineText>` title.
    pub title_json: String,
    /// Optional cover image identifier (URL or local filename).
    pub cover: Option<String>,
    /// Optional icon (emoji / filename / URL) shown next to the title.
    pub icon: Option<String>,
    /// RFC 3339 timestamp of the last update.
    pub updated_at: String,
    /// RFC 3339 timestamp of creation.
    pub created_at: String,
}

/// Converts a [`LeafMeta`] to its FFI representation.
pub(crate) fn leaf_meta_to_ffi(m: LeafMeta) -> LeafMetaFfi {
    let title_plain = m
        .title
        .iter()
        .map(|i| i.content.as_str())
        .collect::<Vec<_>>()
        .join("");
    let title_json = serde_json::to_string(&m.title).unwrap_or_default();
    let published_at = m.published_at;
    LeafMetaFfi {
        id: m.id.to_string(),
        title_plain,
        title_json,
        cover: m.cover,
        updated_at: m.updated_at,
        created_at: m.created_at,
        published_at,
        shelf_id: m.shelf_id.map(|id| id.to_string()),
        parent_leaf_id: m.parent_leaf_id.map(|id| id.to_string()),
        icon: m.icon,
        pinned_at: m.pinned_at,
        manual_order: m.manual_order,
    }
}

/// Converts a [`ShelfMeta`] to its FFI representation.
pub(crate) fn shelf_meta_to_ffi(m: ShelfMeta) -> ShelfMetaFfi {
    ShelfMetaFfi {
        id: m.id.to_string(),
        name: m.name,
        parent_id: m.parent_id.map(|id| id.to_string()),
        created_at: m.created_at,
        updated_at: m.updated_at,
        icon: m.icon,
        manual_order: m.manual_order,
    }
}

/// Converts a [`BookMeta`] to its FFI representation.
pub(crate) fn book_meta_to_ffi(m: BookMeta) -> BookMetaFfi {
    let title_plain = m
        .title
        .iter()
        .map(|i| i.content.as_str())
        .collect::<Vec<_>>()
        .join("");
    let title_json = serde_json::to_string(&m.title).unwrap_or_default();
    BookMetaFfi {
        id: m.id.to_string(),
        title_plain,
        title_json,
        cover: m.cover,
        icon: m.icon,
        updated_at: m.updated_at,
        created_at: m.created_at,
    }
}

/// Bundle of search results across every library surface, returned by
/// `super_search`. Empty arrays mean "no match in that category".
#[derive(Debug, Clone)]
pub struct SuperSearchResultsFfi {
    pub leaves_by_title: Vec<LeafMetaFfi>,
    /// Block-level hits for leaves that did not already match by title.
    pub leaves_by_content: Vec<BlockSearchHitFfi>,
    pub books: Vec<BookMetaFfi>,
    pub shelves: Vec<ShelfMetaFfi>,
}

/// How many items a bulk lifecycle call actually touched, and how many ids
/// it skipped because they were already gone.
#[derive(Debug, Clone)]
pub struct BulkOutcomeFfi {
    pub affected: u32,
    pub skipped: u32,
}

/// Everything the library screen needs, fetched in one FFI crossing.
#[derive(Debug, Clone)]
pub struct LibrarySnapshotFfi {
    pub root_leaves: Vec<LeafMetaFfi>,
    pub all_leaves: Vec<LeafMetaFfi>,
    pub books: Vec<BookMetaFfi>,
    pub shelves: Vec<ShelfMetaFfi>,
}
