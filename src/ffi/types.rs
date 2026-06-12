//! Dictionary types crossing the FFI boundary and their converters.

use crate::domain::database::DatabaseMeta;
use crate::domain::document::DocumentMeta;
use crate::domain::folder::FolderMeta;

// ── Dictionary types ──────────────────────────────────────────────────────────

/// Lightweight document metadata passed across the FFI boundary.
///
/// Carries pre-computed plain-text and JSON representations of the title so
/// that Swift does not need to decode the full document to display a list item.
#[derive(Debug, Clone, serde::Serialize)]
pub struct DocumentMetaFfi {
    /// UUID string of the document.
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
    /// UUID of the folder this document belongs to, or `None` for root.
    pub folder_id: Option<String>,
    /// UUID of the parent document (Notion-style page-in-page), or `None`
    /// when this is a root page.
    pub parent_doc_id: Option<String>,
    /// Optional page icon — emoji or filename. Mirrors `Document.icon`.
    pub icon: Option<String>,
}

/// Lightweight folder metadata passed across the FFI boundary.
#[derive(Debug, Clone, serde::Serialize)]
pub struct FolderMetaFfi {
    /// UUID string of the folder.
    pub id: String,
    /// Display name.
    pub name: String,
    /// UUID of the parent folder, or `None` for a top-level folder.
    pub parent_id: Option<String>,
    /// RFC 3339 creation timestamp.
    pub created_at: String,
    /// RFC 3339 last-update timestamp.
    pub updated_at: String,
    /// Optional emoji icon.
    pub icon: Option<String>,
}

/// Summary of a completed import operation, returned to Swift.
#[derive(Debug, Clone, serde::Serialize)]
pub struct ImportResultFfi {
    /// Human-readable name of the source application (e.g. `"Notion"`, `"Bear"`).
    pub app: String,
    /// UUID string of the Pinkha database created by this import, or empty if
    /// the source had no database structure (plain notes only).
    pub database_id: String,
    /// Number of Pinkha documents created.
    pub documents: u32,
    /// Number of database entries created.
    pub entries: u32,
    /// Number of blocks added across all documents.
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

/// Lightweight Notion database summary returned by `list_notion_databases`.
/// Carries just enough for the picker UI to render a row (title + icon) and
/// kick off an import.
#[derive(Debug, Clone)]
pub struct NotionDatabaseSummaryFfi {
    /// 32-char hex ID. Pass to [`import_from_notion`] as `database_id`.
    pub id: String,
    /// Plain-text title concatenated from Notion's rich-text title runs.
    pub title: String,
    /// Optional emoji icon. Image icons aren't surfaced — the picker uses a
    /// generic database icon when this is empty.
    pub icon_emoji: Option<String>,
    /// ISO 8601 last-edited timestamp from Notion. Already sorted recent-
    /// first by the Rust list call.
    pub last_edited: String,
}

/// One match from a block-content search. Carries the document metadata
/// plus a short snippet of the matching block so the UI can preview
/// where the hit occurs, Notion-style.
#[derive(Debug, Clone, serde::Serialize)]
pub struct BlockSearchHitFfi {
    pub doc: DocumentMetaFfi,
    /// UUID string of the matching block — lets Swift scroll directly
    /// to it when opening the document from a search result.
    pub block_id: String,
    pub snippet: String,
}

/// Lightweight database metadata passed across the FFI boundary.
#[derive(Debug, Clone, serde::Serialize)]
pub struct DatabaseMetaFfi {
    /// UUID string of the database.
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

/// Converts a [`DocumentMeta`] to its FFI representation.
pub(crate) fn doc_meta_to_ffi(m: DocumentMeta) -> DocumentMetaFfi {
    let title_plain = m
        .title
        .iter()
        .map(|i| i.content.as_str())
        .collect::<Vec<_>>()
        .join("");
    let title_json = serde_json::to_string(&m.title).unwrap_or_default();
    let published_at = m.published_at;
    DocumentMetaFfi {
        id: m.id.to_string(),
        title_plain,
        title_json,
        cover: m.cover,
        updated_at: m.updated_at,
        created_at: m.created_at,
        published_at,
        folder_id: m.folder_id.map(|id| id.to_string()),
        parent_doc_id: m.parent_doc_id.map(|id| id.to_string()),
        icon: m.icon,
    }
}

/// Converts a [`FolderMeta`] to its FFI representation.
pub(crate) fn folder_meta_to_ffi(m: FolderMeta) -> FolderMetaFfi {
    FolderMetaFfi {
        id: m.id.to_string(),
        name: m.name,
        parent_id: m.parent_id.map(|id| id.to_string()),
        created_at: m.created_at,
        updated_at: m.updated_at,
        icon: m.icon,
    }
}

/// Converts a [`DatabaseMeta`] to its FFI representation.
pub(crate) fn db_meta_to_ffi(m: DatabaseMeta) -> DatabaseMetaFfi {
    let title_plain = m
        .title
        .iter()
        .map(|i| i.content.as_str())
        .collect::<Vec<_>>()
        .join("");
    let title_json = serde_json::to_string(&m.title).unwrap_or_default();
    DatabaseMetaFfi {
        id: m.id.to_string(),
        title_plain,
        title_json,
        cover: m.cover,
        icon: m.icon,
        updated_at: m.updated_at,
        created_at: m.created_at,
    }
}

/// Bundle of search results across every workspace surface, returned by
/// `super_search`. Empty arrays mean "no match in that category".
#[derive(Debug, Clone)]
pub struct SuperSearchResultsFfi {
    pub documents_by_title: Vec<DocumentMetaFfi>,
    /// Block-level hits for documents that did not already match by title.
    pub documents_by_content: Vec<BlockSearchHitFfi>,
    pub databases: Vec<DatabaseMetaFfi>,
    pub folders: Vec<FolderMetaFfi>,
}
