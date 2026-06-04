use std::collections::HashMap;
use std::sync::OnceLock;

use serde::de::DeserializeOwned;
use uuid::Uuid;

/// Process-wide multi-threaded Tokio runtime used to drive `reqwest`-based
/// extractors from a non-async UniFFI entry point.
///
/// UniFFI 0.31 ships its own foreign-task executor, which is not a Tokio
/// runtime. Polling a `reqwest` future under that executor panics with
/// "there is no reactor running" because reqwest registers I/O with Tokio
/// directly. We sidestep this by exposing the import endpoints as synchronous
/// FFI methods and `block_on`-ing the extractor future on this runtime.
fn tokio_runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .worker_threads(2)
            .thread_name("pinkha-tokio")
            .build()
            .expect("failed to build Tokio runtime for pinkha extractors")
    })
}

use crate::application::error::PinkhaError as CoreError;
use crate::application::{database_use_cases, folder_use_cases, use_cases};
use crate::domain::database::{
    Aggregate, DatabaseMeta, Entry, Filter, Property, PropertyValue, Sort, View,
};
use crate::domain::document::{Block, BlockContent, DocumentMeta};
use crate::domain::folder::FolderMeta;
use crate::domain::parser::parse_inline;
use crate::infrastructure::no_op_unit_of_work::NoOpUnitOfWork;
use crate::infrastructure::sqlite_database_store::SqliteDatabaseStore;
use crate::infrastructure::sqlite_document_store::SqliteDocumentStore;
use crate::infrastructure::sqlite_folder_store::SqliteFolderStore;

// ── FFI error ─────────────────────────────────────────────────────────────────

/// Error type exposed to Swift across the FFI boundary.
///
/// Maps the internal [`CoreError`] variants to three coarse categories that
/// are easy to handle in Swift: a resource was not found, the caller sent
/// invalid input, or a storage-layer problem occurred.
#[derive(Debug)]
pub enum PinkhaError {
    /// A resource identified by `id` could not be found.
    NotFound { id: String },
    /// The operation was rejected because of invalid input.
    InvalidOperation { detail: String },
    /// A storage-layer error occurred (I/O, JSON serialization, SQLite).
    Storage { detail: String },
}

impl std::fmt::Display for PinkhaError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotFound { id } => write!(f, "non trouvé : {id}"),
            Self::InvalidOperation { detail } => write!(f, "opération invalide : {detail}"),
            Self::Storage { detail } => write!(f, "stockage : {detail}"),
        }
    }
}

impl std::error::Error for PinkhaError {}

impl From<CoreError> for PinkhaError {
    fn from(e: CoreError) -> Self {
        match e {
            CoreError::NotFound(id) => Self::NotFound { id: id.to_string() },
            CoreError::InvalidOperation(msg) => Self::InvalidOperation { detail: msg },
            CoreError::Io(e) => Self::Storage {
                detail: e.to_string(),
            },
            CoreError::Json(e) => Self::Storage {
                detail: e.to_string(),
            },
            CoreError::Db(msg) => Self::Storage { detail: msg },
        }
    }
}

// ── Dictionary types ──────────────────────────────────────────────────────────

/// Lightweight document metadata passed across the FFI boundary.
///
/// Carries pre-computed plain-text and JSON representations of the title so
/// that Swift does not need to decode the full document to display a list item.
#[derive(Debug, Clone)]
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
    /// UUID of the folder this document belongs to, or `None` for root.
    pub folder_id: Option<String>,
    /// UUID of the parent document (Notion-style page-in-page), or `None`
    /// when this is a root page.
    pub parent_doc_id: Option<String>,
    /// Optional page icon — emoji or filename. Mirrors `Document.icon`.
    pub icon: Option<String>,
}

/// Lightweight folder metadata passed across the FFI boundary.
#[derive(Debug, Clone)]
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
#[derive(Debug, Clone)]
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

/// Lightweight database metadata passed across the FFI boundary.
#[derive(Debug, Clone)]
pub struct DatabaseMetaFfi {
    /// UUID string of the database.
    pub id: String,
    /// Concatenated plain-text title.
    pub title_plain: String,
    /// JSON-encoded `Vec<InlineText>` title.
    pub title_json: String,
    /// RFC 3339 timestamp of the last update.
    pub updated_at: String,
    /// RFC 3339 timestamp of creation.
    pub created_at: String,
}

/// Converts a [`DocumentMeta`] to its FFI representation.
fn doc_meta_to_ffi(m: DocumentMeta) -> DocumentMetaFfi {
    let title_plain = m
        .title
        .iter()
        .map(|i| i.content.as_str())
        .collect::<Vec<_>>()
        .join("");
    let title_json = serde_json::to_string(&m.title).unwrap_or_default();
    DocumentMetaFfi {
        id: m.id.to_string(),
        title_plain,
        title_json,
        cover: m.cover,
        updated_at: m.updated_at,
        created_at: m.created_at,
        folder_id: m.folder_id.map(|id| id.to_string()),
        parent_doc_id: m.parent_doc_id.map(|id| id.to_string()),
        icon: m.icon,
    }
}

/// Converts a [`FolderMeta`] to its FFI representation.
fn folder_meta_to_ffi(m: FolderMeta) -> FolderMetaFfi {
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
fn db_meta_to_ffi(m: DatabaseMeta) -> DatabaseMetaFfi {
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
        updated_at: m.updated_at,
        created_at: m.created_at,
    }
}

/// Maximum size of JSON payloads accepted at the FFI boundary (5 MB).
///
/// Guards against oversized requests that would saturate memory.
const MAX_JSON_BYTES: usize = 5 * 1024 * 1024;

/// Maximum size of a string input (title, search query).
const MAX_STRING_BYTES: usize = 64 * 1024;

/// Parses a UUID string, returning an [`InvalidOperation`] error on failure.
fn parse_uuid(s: &str) -> Result<Uuid, PinkhaError> {
    Uuid::parse_str(s).map_err(|_| PinkhaError::InvalidOperation {
        detail: format!("UUID invalide : {s}"),
    })
}

/// Parses a list of UUID strings, returning on the first failure.
fn parse_uuids(ids: Vec<String>) -> Result<Vec<Uuid>, PinkhaError> {
    ids.iter().map(|s| parse_uuid(s)).collect()
}

/// Rejects strings that exceed [`MAX_STRING_BYTES`] at the FFI boundary.
fn validate_string(s: &str, field: &str) -> Result<(), PinkhaError> {
    if s.len() > MAX_STRING_BYTES {
        return Err(PinkhaError::InvalidOperation {
            detail: format!(
                "{field} trop grand : {} octets (max {MAX_STRING_BYTES})",
                s.len()
            ),
        });
    }
    Ok(())
}

/// Deserializes a JSON string, enforcing the [`MAX_JSON_BYTES`] size limit.
fn parse_json<T: DeserializeOwned>(json: &str) -> Result<T, PinkhaError> {
    if json.len() > MAX_JSON_BYTES {
        return Err(PinkhaError::InvalidOperation {
            detail: format!(
                "payload JSON trop grand : {} octets (max {MAX_JSON_BYTES})",
                json.len()
            ),
        });
    }
    serde_json::from_str(json).map_err(|e| PinkhaError::InvalidOperation {
        detail: e.to_string(),
    })
}

/// Serializes a value to JSON, mapping errors to [`Storage`].
fn to_json<T: serde::Serialize>(value: &T) -> Result<String, PinkhaError> {
    serde_json::to_string(value).map_err(|e| PinkhaError::Storage {
        detail: e.to_string(),
    })
}

/// Extracts the UUID string from a [`Block`].
fn get_block_id(block: Block) -> String {
    block.id.to_string()
}

// ── Main facade ───────────────────────────────────────────────────────────────

/// Top-level API exposed to Swift via UniFFI.
///
/// Opens both the document and database SQLite stores at the same file path
/// and exposes all CRUD operations for documents, blocks, and databases.
/// Blocks and full databases cross the boundary as JSON strings (Swift decodes
/// them with `Codable`) to avoid expressing recursive types in the UDL.
pub struct PinkhaApi {
    docs: SqliteDocumentStore,
    dbs: SqliteDatabaseStore,
    folders: SqliteFolderStore,
}

impl PinkhaApi {
    /// Creates a new API instance backed by a SQLite file at `db_path`.
    pub fn new(db_path: String) -> Result<Self, PinkhaError> {
        let docs = SqliteDocumentStore::new(&db_path).map_err(PinkhaError::from)?;
        let dbs = SqliteDatabaseStore::new(&db_path).map_err(PinkhaError::from)?;
        let folders = SqliteFolderStore::new(&db_path).map_err(PinkhaError::from)?;
        Ok(Self { docs, dbs, folders })
    }

    /// Opens a non-transactional unit of work that borrows the three
    /// repositories. Use cases consume `&dyn UnitOfWork`; this is the bridge
    /// that wires the composition root to each call. The returned UoW's
    /// `commit()` is a no-op (the underlying stores write through their own
    /// SQLite connections); a future transactional impl will swap in here.
    fn uow(&self) -> NoOpUnitOfWork<'_> {
        NoOpUnitOfWork::new(&self.docs, &self.dbs, &self.folders)
    }

    // ── Documents ─────────────────────────────────────────────

    /// Creates a new document with the given plain-text title.
    /// Returns the UUID string of the created document.
    pub fn create_document(&self, title: String) -> Result<String, PinkhaError> {
        validate_string(&title, "title")?;
        let doc = use_cases::create_document(&self.uow(), &title).map_err(PinkhaError::from)?;
        Ok(doc.id.to_string())
    }

    /// Returns the full document as a JSON string (decodable as `DocumentFfi` in Swift).
    pub fn get_document_json(&self, id: String) -> Result<String, PinkhaError> {
        let uuid = parse_uuid(&id)?;
        let doc = use_cases::get_document(&self.uow(), uuid).map_err(PinkhaError::from)?;
        serde_json::to_string(&doc).map_err(|e| PinkhaError::Storage {
            detail: e.to_string(),
        })
    }

    /// Returns lightweight metadata for all non-deleted documents.
    pub fn list_documents(&self) -> Result<Vec<DocumentMetaFfi>, PinkhaError> {
        let metas = use_cases::list_documents(&self.uow()).map_err(PinkhaError::from)?;
        Ok(metas.into_iter().map(doc_meta_to_ffi).collect())
    }

    /// Soft-deletes the document identified by `id`.
    pub fn delete_document(&self, id: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        use_cases::delete_document(&self.uow(), uuid).map_err(PinkhaError::from)
    }

    /// Soft-deletes every document. Returns the number of documents deleted.
    pub fn delete_all_documents(&self) -> Result<u32, PinkhaError> {
        let metas = use_cases::list_documents(&self.uow()).map_err(PinkhaError::from)?;
        let count = metas.len() as u32;
        for meta in metas {
            use_cases::delete_document(&self.uow(), meta.id).map_err(PinkhaError::from)?;
        }
        Ok(count)
    }

    /// Replaces the document title with a plain-text string parsed into inline spans.
    pub fn update_document_title(&self, id: String, new_title: String) -> Result<(), PinkhaError> {
        validate_string(&new_title, "new_title")?;
        let uuid = parse_uuid(&id)?;
        use_cases::update_document_title(&self.uow(), uuid, &new_title).map_err(PinkhaError::from)
    }

    /// Sets or clears the cover of a document.
    pub fn update_document_cover(
        &self,
        id: String,
        cover: Option<String>,
    ) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        use_cases::update_document_cover(&self.uow(), uuid, cover).map_err(PinkhaError::from)
    }

    /// Sets or clears the page icon. Accepts an emoji, a local cover-dir
    /// filename, or a remote URL — the renderer picks the right strategy.
    pub fn update_document_icon(
        &self,
        id: String,
        icon: Option<String>,
    ) -> Result<(), PinkhaError> {
        if let Some(i) = icon.as_deref() {
            validate_string(i, "icon")?;
        }
        let uuid = parse_uuid(&id)?;
        use_cases::update_document_icon(&self.uow(), uuid, icon).map_err(PinkhaError::from)
    }

    /// Sets the read-only lock on a document. Used by the editor toggle and
    /// auto-applied by data-extract imports (Notion/Bear/Craft) which lock
    /// new documents by default — the user reads first, unlocks before
    /// editing imported content.
    pub fn update_document_locked(
        &self,
        id: String,
        locked: bool,
    ) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        use_cases::update_document_locked(&self.uow(), uuid, locked).map_err(PinkhaError::from)
    }

    /// Appends a block to a document. `block_content_json` must be a JSON-encoded
    /// [`BlockContent`]. Returns the UUID string of the newly created block.
    pub fn add_block(
        &self,
        doc_id: String,
        block_content_json: String,
    ) -> Result<String, PinkhaError> {
        let uuid = parse_uuid(&doc_id)?;
        let content: BlockContent = parse_json(&block_content_json)?;
        let doc = use_cases::add_block(&self.uow(), uuid, content).map_err(PinkhaError::from)?;
        doc.blocks
            .last()
            .map(|b| b.id.to_string())
            .ok_or_else(|| PinkhaError::InvalidOperation {
                detail: "bloc introuvable après ajout".to_string(),
            })
    }

    /// Replaces the content of an existing block. `content_json` must be a
    /// JSON-encoded [`BlockContent`].
    pub fn update_block(
        &self,
        doc_id: String,
        block_id: String,
        content_json: String,
    ) -> Result<(), PinkhaError> {
        let doc_uuid = parse_uuid(&doc_id)?;
        let block_uuid = parse_uuid(&block_id)?;
        let content: BlockContent = parse_json(&content_json)?;
        use_cases::update_block(&self.uow(), doc_uuid, block_uuid, content)
            .map_err(PinkhaError::from)
    }

    /// Sets the block-level text color, or clears it when `color` is `None`.
    ///
    /// Color is a color name like `"red"` / `"blue"` / `"green"` etc. — the
    /// rendering layer maps the name to a concrete value. Inline color styles
    /// on individual spans always override the block color.
    pub fn set_block_color(
        &self,
        doc_id: String,
        block_id: String,
        color: Option<String>,
    ) -> Result<(), PinkhaError> {
        if let Some(c) = color.as_deref() {
            validate_string(c, "color")?;
        }
        let doc_uuid = parse_uuid(&doc_id)?;
        let block_uuid = parse_uuid(&block_id)?;
        use_cases::set_block_color(&self.uow(), doc_uuid, block_uuid, color)
            .map_err(PinkhaError::from)
    }

    /// Removes a block (and all its children) from a document.
    pub fn delete_block(&self, doc_id: String, block_id: String) -> Result<(), PinkhaError> {
        let doc_uuid = parse_uuid(&doc_id)?;
        let block_uuid = parse_uuid(&block_id)?;
        use_cases::delete_block(&self.uow(), doc_uuid, block_uuid).map_err(PinkhaError::from)
    }

    /// Reorders the root-level blocks of a document according to `order`.
    /// Blocks not mentioned in `order` are appended at the end.
    pub fn reorder_blocks(&self, doc_id: String, order: Vec<String>) -> Result<(), PinkhaError> {
        let doc_uuid = parse_uuid(&doc_id)?;
        let uuids = parse_uuids(order)?;
        use_cases::reorder_blocks(&self.uow(), doc_uuid, uuids).map_err(PinkhaError::from)
    }

    /// Appends a child block under `parent_id`. Returns the new block UUID string.
    pub fn add_child_block(
        &self,
        doc_id: String,
        parent_id: String,
        block_content_json: String,
    ) -> Result<String, PinkhaError> {
        let doc_uuid = parse_uuid(&doc_id)?;
        let parent_uuid = parse_uuid(&parent_id)?;
        let content: BlockContent = parse_json(&block_content_json)?;
        use_cases::add_child_block(&self.uow(), doc_uuid, parent_uuid, content)
            .map(get_block_id)
            .map_err(PinkhaError::from)
    }

    /// Reorders the children of `parent_id` according to `order`.
    pub fn reorder_child_blocks(
        &self,
        doc_id: String,
        parent_id: String,
        order: Vec<String>,
    ) -> Result<(), PinkhaError> {
        let doc_uuid = parse_uuid(&doc_id)?;
        let parent_uuid = parse_uuid(&parent_id)?;
        let uuids = parse_uuids(order)?;
        use_cases::reorder_child_blocks(&self.uow(), doc_uuid, parent_uuid, uuids)
            .map_err(PinkhaError::from)
    }

    /// Moves a block to a new parent. Pass `None` for `new_parent_id` to move
    /// the block to the document root.
    pub fn move_block(
        &self,
        doc_id: String,
        block_id: String,
        new_parent_id: Option<String>,
    ) -> Result<(), PinkhaError> {
        let doc_uuid = parse_uuid(&doc_id)?;
        let block_uuid = parse_uuid(&block_id)?;
        let parent_uuid = new_parent_id.as_deref().map(parse_uuid).transpose()?;
        use_cases::move_block(&self.uow(), doc_uuid, block_uuid, parent_uuid)
            .map_err(PinkhaError::from)
    }

    /// Indents a block — moves it under the previous sibling at the same
    /// level. Fails with `InvalidOperation` when the block is the first of
    /// its level (nothing to indent under).
    pub fn indent_block(&self, doc_id: String, block_id: String) -> Result<(), PinkhaError> {
        let doc_uuid = parse_uuid(&doc_id)?;
        let block_uuid = parse_uuid(&block_id)?;
        use_cases::indent_block(&self.uow(), doc_uuid, block_uuid).map_err(PinkhaError::from)
    }

    /// Outdents a block — moves it out of its current parent up to the
    /// grandparent level, inserted right after the former parent. Fails with
    /// `InvalidOperation` when the block is already at the document root.
    pub fn outdent_block(&self, doc_id: String, block_id: String) -> Result<(), PinkhaError> {
        let doc_uuid = parse_uuid(&doc_id)?;
        let block_uuid = parse_uuid(&block_id)?;
        use_cases::outdent_block(&self.uow(), doc_uuid, block_uuid).map_err(PinkhaError::from)
    }

    /// Searches document titles for `query` (case-insensitive).
    pub fn search_documents(&self, query: String) -> Result<Vec<DocumentMetaFfi>, PinkhaError> {
        validate_string(&query, "query")?;
        let metas = use_cases::search_documents(&self.uow(), &query).map_err(PinkhaError::from)?;
        Ok(metas.into_iter().map(doc_meta_to_ffi).collect())
    }

    /// Full-text search across all block content in all documents (case-insensitive).
    pub fn search_in_blocks(&self, query: String) -> Result<Vec<DocumentMetaFfi>, PinkhaError> {
        validate_string(&query, "query")?;
        let metas = use_cases::search_in_blocks(&self.uow(), &query).map_err(PinkhaError::from)?;
        Ok(metas.into_iter().map(doc_meta_to_ffi).collect())
    }

    // ── Trash (soft-deleted documents) ────────────────────────────────────────

    /// Lists soft-deleted documents (the trash). Newest-deleted first.
    pub fn list_deleted_documents(&self) -> Result<Vec<DocumentMetaFfi>, PinkhaError> {
        let metas = use_cases::list_deleted_documents(&self.uow()).map_err(PinkhaError::from)?;
        Ok(metas.into_iter().map(doc_meta_to_ffi).collect())
    }

    /// Restores a soft-deleted document.
    pub fn restore_document(&self, id: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        use_cases::restore_document(&self.uow(), uuid).map_err(PinkhaError::from)
    }

    /// Permanently deletes a soft-deleted document (purge from trash).
    pub fn purge_document(&self, id: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        use_cases::purge_document(&self.uow(), uuid).map_err(PinkhaError::from)
    }
}

// ── Database facade ───────────────────────────────────────────────────────────

impl PinkhaApi {
    /// Creates a new database with a plain-text title parsed into inline spans.
    /// Returns the UUID string of the created database.
    pub fn create_database(&self, title: String) -> Result<String, PinkhaError> {
        validate_string(&title, "title")?;
        let db = database_use_cases::create_database(&self.uow(), parse_inline(&title), vec![])
            .map_err(PinkhaError::from)?;
        Ok(db.id.to_string())
    }

    /// Returns the full database as a JSON string.
    pub fn get_database_json(&self, id: String) -> Result<String, PinkhaError> {
        let uuid = parse_uuid(&id)?;
        let db = database_use_cases::get_database(&self.uow(), uuid).map_err(PinkhaError::from)?;
        serde_json::to_string(&db).map_err(|e| PinkhaError::Storage {
            detail: e.to_string(),
        })
    }

    /// Returns lightweight metadata for all non-deleted databases.
    pub fn list_databases(&self) -> Result<Vec<DatabaseMetaFfi>, PinkhaError> {
        let metas = database_use_cases::list_databases(&self.uow()).map_err(PinkhaError::from)?;
        Ok(metas.into_iter().map(db_meta_to_ffi).collect())
    }

    /// Soft-deletes the database identified by `id`.
    pub fn delete_database(&self, id: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        database_use_cases::delete_database(&self.uow(), uuid).map_err(PinkhaError::from)
    }

    /// Soft-deletes every database. Returns the number deleted.
    pub fn delete_all_databases(&self) -> Result<u32, PinkhaError> {
        let metas = database_use_cases::list_databases(&self.uow()).map_err(PinkhaError::from)?;
        let count = metas.len() as u32;
        for meta in metas {
            database_use_cases::delete_database(&self.uow(), meta.id).map_err(PinkhaError::from)?;
        }
        Ok(count)
    }

    /// Adds an entry to a database. `values_json` must be a JSON-encoded
    /// `HashMap<Uuid, PropertyValue>`. Returns the new entry UUID string.
    pub fn add_entry(&self, db_id: String, values_json: String) -> Result<String, PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let values: HashMap<Uuid, PropertyValue> = parse_json(&values_json)?;
        let entry = database_use_cases::add_entry(&self.uow(), db_uuid, values)
            .map_err(PinkhaError::from)?;
        Ok(entry.id.to_string())
    }

    /// Replaces all property values of an existing entry. When the entry is
    /// linked to a document and the new values touch the Title property, the
    /// document title is updated in lockstep — fixing the UX bug where
    /// renaming a row in the DB view left the underlying note's title stale.
    pub fn update_entry(
        &self,
        db_id: String,
        entry_id: String,
        values_json: String,
    ) -> Result<(), PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let entry_uuid = parse_uuid(&entry_id)?;
        let values: HashMap<Uuid, PropertyValue> = parse_json(&values_json)?;
        use_cases::update_entry_propagating_title(&self.uow(), db_uuid, entry_uuid, values)
            .map_err(PinkhaError::from)
    }

    /// Soft-deletes an entry — recoverable via `restore_entry`.
    pub fn delete_entry(&self, db_id: String, entry_id: String) -> Result<(), PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let entry_uuid = parse_uuid(&entry_id)?;
        database_use_cases::delete_entry(&self.uow(), db_uuid, entry_uuid)
            .map_err(PinkhaError::from)
    }

    /// Restores a soft-deleted entry.
    pub fn restore_entry(&self, db_id: String, entry_id: String) -> Result<(), PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let entry_uuid = parse_uuid(&entry_id)?;
        database_use_cases::restore_entry(&self.uow(), db_uuid, entry_uuid)
            .map_err(PinkhaError::from)
    }

    /// Permanently deletes a soft-deleted entry (purge from trash).
    pub fn purge_entry(&self, db_id: String, entry_id: String) -> Result<(), PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let entry_uuid = parse_uuid(&entry_id)?;
        database_use_cases::purge_entry(&self.uow(), db_uuid, entry_uuid).map_err(PinkhaError::from)
    }

    /// Lists soft-deleted entries of a database as a JSON array.
    pub fn list_deleted_entries_json(&self, db_id: String) -> Result<String, PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let entries = database_use_cases::list_deleted_entries(&self.uow(), db_uuid)
            .map_err(PinkhaError::from)?;
        to_json(&entries)
    }

    /// Lists soft-deleted databases (the trash). Newest-deleted first.
    pub fn list_deleted_databases(&self) -> Result<Vec<DatabaseMetaFfi>, PinkhaError> {
        let metas =
            database_use_cases::list_deleted_databases(&self.uow()).map_err(PinkhaError::from)?;
        Ok(metas.into_iter().map(db_meta_to_ffi).collect())
    }

    /// Restores a soft-deleted database.
    pub fn restore_database(&self, id: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        database_use_cases::restore_database(&self.uow(), uuid).map_err(PinkhaError::from)
    }

    /// Permanently deletes a soft-deleted database (purge from trash).
    pub fn purge_database(&self, id: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        database_use_cases::purge_database(&self.uow(), uuid).map_err(PinkhaError::from)
    }

    /// Adds a property to an existing database. `property_json` must be a
    /// JSON-encoded [`Property`].
    pub fn add_property(&self, db_id: String, property_json: String) -> Result<(), PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let property: Property = parse_json(&property_json)?;
        database_use_cases::add_property(&self.uow(), db_uuid, property).map_err(PinkhaError::from)
    }

    /// Renames a property in an existing database.
    pub fn rename_property(
        &self,
        db_id: String,
        property_id: String,
        new_name: String,
    ) -> Result<(), PinkhaError> {
        validate_string(&new_name, "new_name")?;
        let db_uuid = parse_uuid(&db_id)?;
        let prop_uuid = parse_uuid(&property_id)?;
        database_use_cases::rename_property(&self.uow(), db_uuid, prop_uuid, &new_name)
            .map_err(PinkhaError::from)
    }

    /// Removes a property from a database and clears its values in all entries.
    pub fn delete_property(&self, db_id: String, property_id: String) -> Result<(), PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let prop_uuid = parse_uuid(&property_id)?;
        database_use_cases::delete_property(&self.uow(), db_uuid, prop_uuid)
            .map_err(PinkhaError::from)
    }

    /// Adds a view to a database. `view_json` must be a JSON-encoded [`View`].
    /// Returns the new view UUID string.
    pub fn add_view(&self, db_id: String, view_json: String) -> Result<String, PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let view: View = parse_json(&view_json)?;
        let view =
            database_use_cases::add_view(&self.uow(), db_uuid, view).map_err(PinkhaError::from)?;
        Ok(view.id.to_string())
    }

    /// Updates the filters and sorts of an existing view.
    pub fn update_view(
        &self,
        db_id: String,
        view_id: String,
        filters_json: String,
        sorts_json: String,
    ) -> Result<(), PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let view_uuid = parse_uuid(&view_id)?;
        let filters: Vec<Filter> = parse_json(&filters_json)?;
        let sorts: Vec<Sort> = parse_json(&sorts_json)?;
        database_use_cases::update_view(&self.uow(), db_uuid, view_uuid, filters, sorts)
            .map_err(PinkhaError::from)
    }

    /// Sets a single sort on a view, replacing previous sorts. `property_id`
    /// = `None` clears the sort. Used by the DB view column-header tap
    /// gesture — callers don't have to know the `Sort`/`SortSource` JSON
    /// shape, the orchestration lives in Rust.
    pub fn set_view_sort(
        &self,
        db_id: String,
        view_id: String,
        property_id: Option<String>,
        ascending: bool,
    ) -> Result<(), PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let view_uuid = parse_uuid(&view_id)?;
        let prop_uuid = property_id.as_deref().map(parse_uuid).transpose()?;
        database_use_cases::set_view_single_sort(
            &self.uow(),
            db_uuid,
            view_uuid,
            prop_uuid,
            ascending,
        )
        .map_err(PinkhaError::from)
    }

    /// Removes a view from a database. Fails if it is the last view.
    pub fn delete_view(&self, db_id: String, view_id: String) -> Result<(), PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let view_uuid = parse_uuid(&view_id)?;
        database_use_cases::delete_view(&self.uow(), db_uuid, view_uuid).map_err(PinkhaError::from)
    }

    /// Runs the filters and sorts defined on a view and returns matching entries
    /// as a JSON array.
    pub fn query_database_json(
        &self,
        db_id: String,
        view_id: String,
    ) -> Result<String, PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let view_uuid = parse_uuid(&view_id)?;
        let entries: Vec<Entry> = database_use_cases::query(&self.uow(), db_uuid, view_uuid)
            .map_err(PinkhaError::from)?;
        to_json(&entries)
    }

    /// Same as [`query_database_json`] but with rollup columns computed at read
    /// time.
    pub fn query_database_with_rollups_json(
        &self,
        db_id: String,
        view_id: String,
    ) -> Result<String, PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let view_uuid = parse_uuid(&view_id)?;
        let entries: Vec<Entry> =
            database_use_cases::query_with_rollups(&self.uow(), db_uuid, view_uuid)
                .map_err(PinkhaError::from)?;
        to_json(&entries)
    }

    /// Groups entries by `group_by` property and returns a JSON array of groups.
    pub fn grouped_query_database_json(
        &self,
        db_id: String,
        view_id: String,
        group_by: String,
    ) -> Result<String, PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let view_uuid = parse_uuid(&view_id)?;
        let prop_uuid = parse_uuid(&group_by)?;
        let groups = database_use_cases::grouped_query(&self.uow(), db_uuid, view_uuid, prop_uuid)
            .map_err(PinkhaError::from)?;
        to_json(&groups)
    }

    /// Computes a column aggregate and returns the result as a JSON-encoded
    /// [`PropertyValue`].
    pub fn column_aggregate_database_json(
        &self,
        db_id: String,
        property_id: String,
        aggregate_json: String,
    ) -> Result<String, PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let prop_uuid = parse_uuid(&property_id)?;
        let aggregate: Aggregate = parse_json(&aggregate_json)?;
        let value =
            database_use_cases::column_aggregate(&self.uow(), db_uuid, prop_uuid, aggregate)
                .map_err(PinkhaError::from)?;
        to_json(&value)
    }

    /// Searches all text-valued properties of a database's entries for `query`
    /// (case-insensitive). Returns matching entries as a JSON array.
    pub fn search_database_entries_json(
        &self,
        db_id: String,
        query: String,
    ) -> Result<String, PinkhaError> {
        validate_string(&query, "query")?;
        let db_uuid = parse_uuid(&db_id)?;
        let entries = database_use_cases::search_entries(&self.uow(), db_uuid, &query)
            .map_err(PinkhaError::from)?;
        to_json(&entries)
    }

    // ── Folders ───────────────────────────────────────────────────────────────

    pub fn create_folder(
        &self,
        name: String,
        parent_id: Option<String>,
    ) -> Result<FolderMetaFfi, PinkhaError> {
        validate_string(&name, "name")?;
        let pid = parent_id.as_deref().map(parse_uuid).transpose()?;
        let folder =
            folder_use_cases::create_folder(&self.uow(), &name, pid).map_err(PinkhaError::from)?;
        Ok(folder_meta_to_ffi((&folder).into()))
    }

    pub fn get_folder(&self, id: String) -> Result<FolderMetaFfi, PinkhaError> {
        let uuid = parse_uuid(&id)?;
        let folder = folder_use_cases::get_folder(&self.uow(), uuid).map_err(PinkhaError::from)?;
        Ok(folder_meta_to_ffi((&folder).into()))
    }

    pub fn list_folders(&self) -> Result<Vec<FolderMetaFfi>, PinkhaError> {
        folder_use_cases::list_folders(&self.uow())
            .map(|v| v.into_iter().map(folder_meta_to_ffi).collect())
            .map_err(PinkhaError::from)
    }

    pub fn rename_folder(&self, id: String, new_name: String) -> Result<(), PinkhaError> {
        validate_string(&new_name, "new_name")?;
        let uuid = parse_uuid(&id)?;
        folder_use_cases::rename_folder(&self.uow(), uuid, &new_name).map_err(PinkhaError::from)
    }

    /// Sets or clears a folder's emoji icon. Pass `None` to remove.
    pub fn update_folder_icon(
        &self,
        id: String,
        icon: Option<String>,
    ) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        folder_use_cases::update_folder_icon(&self.uow(), uuid, icon.as_deref())
            .map_err(PinkhaError::from)
    }

    pub fn delete_folder(&self, id: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        folder_use_cases::delete_folder(&self.uow(), uuid).map_err(PinkhaError::from)
    }

    /// Soft-deletes every folder. Documents and databases that lived inside
    /// are orphaned to the root (the `delete_folder` use case handles that).
    /// Returns the number of folders deleted.
    pub fn delete_all_folders(&self) -> Result<u32, PinkhaError> {
        let metas = folder_use_cases::list_folders(&self.uow()).map_err(PinkhaError::from)?;
        let count = metas.len() as u32;
        for meta in metas {
            folder_use_cases::delete_folder(&self.uow(), meta.id).map_err(PinkhaError::from)?;
        }
        Ok(count)
    }

    /// Lists soft-deleted folders (the trash). Newest-deleted first.
    pub fn list_deleted_folders(&self) -> Result<Vec<FolderMetaFfi>, PinkhaError> {
        folder_use_cases::list_deleted_folders(&self.uow())
            .map(|v| v.into_iter().map(folder_meta_to_ffi).collect())
            .map_err(PinkhaError::from)
    }

    /// Restores a soft-deleted folder.
    pub fn restore_folder(&self, id: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        folder_use_cases::restore_folder(&self.uow(), uuid).map_err(PinkhaError::from)
    }

    /// Permanently deletes a soft-deleted folder (purge from trash).
    pub fn purge_folder(&self, id: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        folder_use_cases::purge_folder(&self.uow(), uuid).map_err(PinkhaError::from)
    }

    pub fn move_folder_to(
        &self,
        id: String,
        new_parent_id: Option<String>,
    ) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        let pid = new_parent_id.as_deref().map(parse_uuid).transpose()?;
        folder_use_cases::move_folder(&self.uow(), uuid, pid).map_err(PinkhaError::from)
    }

    pub fn move_document_to_folder(
        &self,
        doc_id: String,
        folder_id: Option<String>,
    ) -> Result<(), PinkhaError> {
        let doc_uuid = parse_uuid(&doc_id)?;
        let fid = folder_id.as_deref().map(parse_uuid).transpose()?;
        use_cases::move_document_to_folder(&self.uow(), doc_uuid, fid).map_err(PinkhaError::from)
    }

    pub fn list_documents_in_folder(
        &self,
        folder_id: Option<String>,
    ) -> Result<Vec<DocumentMetaFfi>, PinkhaError> {
        let fid = folder_id.as_deref().map(parse_uuid).transpose()?;
        use_cases::list_documents_in_folder(&self.uow(), fid)
            .map(|v| v.into_iter().map(doc_meta_to_ffi).collect())
            .map_err(PinkhaError::from)
    }

    /// Sets the parent document for page-in-page hierarchy. Pass `None`
    /// to promote the document back to root. Rejects cycles.
    pub fn update_document_parent(
        &self,
        doc_id: String,
        new_parent_doc_id: Option<String>,
    ) -> Result<(), PinkhaError> {
        let doc_uuid = parse_uuid(&doc_id)?;
        let parent = new_parent_doc_id
            .as_deref()
            .map(parse_uuid)
            .transpose()?;
        use_cases::update_document_parent(&self.uow(), doc_uuid, parent).map_err(PinkhaError::from)
    }

    /// Lists root pages (documents with no parent). Drives the home view.
    pub fn list_root_documents(&self) -> Result<Vec<DocumentMetaFfi>, PinkhaError> {
        use_cases::list_root_documents(&self.uow())
            .map(|v| v.into_iter().map(doc_meta_to_ffi).collect())
            .map_err(PinkhaError::from)
    }

    /// Lists direct children of a parent document. Used by the child-pages
    /// section in the document view and by the breadcrumbs picker.
    pub fn list_child_documents(
        &self,
        parent_doc_id: String,
    ) -> Result<Vec<DocumentMetaFfi>, PinkhaError> {
        let parent = parse_uuid(&parent_doc_id)?;
        use_cases::list_child_documents(&self.uow(), parent)
            .map(|v| v.into_iter().map(doc_meta_to_ffi).collect())
            .map_err(PinkhaError::from)
    }

    // ── Extractors ────────────────────────────────────────────────────────────
    //
    // Async import methods — one per source application.
    // Each method creates the appropriate extractor and delegates to its `run`.
    //
    // UDL: mark with [Async][Throws=PinkhaError] when wiring up each extractor.
    // OAuth2 token exchange happens in Swift before calling these methods;
    // Rust only receives the final bearer token.

    /// Imports a Notion database into Pinkha.
    ///
    /// `token`       — Notion bearer token (OAuth2 or private integration token).
    /// `database_id` — 32-char hex ID or full Notion URL of the database.
    ///
    /// Synchronous on the FFI boundary: the extractor uses `reqwest`, which
    /// needs a Tokio reactor, and UniFFI's foreign-task executor doesn't
    /// provide one. We block on the process-wide Tokio runtime so callers must
    /// dispatch this method off the main thread themselves (e.g. via Swift's
    /// `Task.detached`). See [`tokio_runtime`] for the rationale.
    /// Lists every Notion database the OAuth token can see — used by the
    /// picker UI so the user can multi-select databases to import without
    /// copy-pasting URLs. Sync for the same Tokio-reactor reason as
    /// `import_from_notion` (cf. [`tokio_runtime`]).
    pub fn list_notion_databases(
        &self,
        token: String,
    ) -> Result<Vec<NotionDatabaseSummaryFfi>, PinkhaError> {
        validate_string(&token, "token")?;
        let summaries = tokio_runtime()
            .block_on(crate::extractors::notion::list_databases(&token))
            .map_err(|e| match e {
                crate::extractors::ExtractorError::Http { status, message } => {
                    PinkhaError::Storage {
                        detail: format!("Notion HTTP {status}: {message}"),
                    }
                }
                crate::extractors::ExtractorError::Auth(msg) => {
                    PinkhaError::InvalidOperation { detail: msg }
                }
                crate::extractors::ExtractorError::Parse(msg) => {
                    PinkhaError::Storage { detail: msg }
                }
                crate::extractors::ExtractorError::Storage(e) => e.into(),
            })?;
        Ok(summaries
            .into_iter()
            .map(|s| NotionDatabaseSummaryFfi {
                id: s.id,
                title: s.title,
                icon_emoji: s.icon_emoji,
                last_edited: s.last_edited,
            })
            .collect())
    }

    pub fn import_from_notion(
        &self,
        token: String,
        database_id: String,
        covers_dir: Option<String>,
    ) -> Result<ImportResultFfi, PinkhaError> {
        use crate::extractors::notion::{NotionConfig, NotionExtractor};
        use crate::extractors::traits::Extractor;
        validate_string(&token, "token")?;
        validate_string(&database_id, "database_id")?;
        if let Some(dir) = covers_dir.as_deref() {
            validate_string(dir, "covers_dir")?;
        }
        let extractor = NotionExtractor::new();
        let config = NotionConfig {
            token,
            database_id,
            covers_dir,
        };
        tokio_runtime()
            .block_on(extractor.run(
                config,
                &self.docs
                    as &(dyn crate::application::repository::DocumentRepository + Send + Sync),
                &self.dbs
                    as &(
                         dyn crate::application::database_repository::DatabaseRepository
                             + Send
                             + Sync
                     ),
                &self.folders,
            ))
            .map(ffi_import_result)
            .map_err(|e| match e {
                crate::extractors::ExtractorError::Http { status, message } => {
                    PinkhaError::Storage {
                        detail: format!("Notion HTTP {status}: {message}"),
                    }
                }
                crate::extractors::ExtractorError::Auth(msg) => {
                    PinkhaError::InvalidOperation { detail: msg }
                }
                crate::extractors::ExtractorError::Parse(msg) => {
                    PinkhaError::Storage { detail: msg }
                }
                crate::extractors::ExtractorError::Storage(e) => e.into(),
            })
    }

    /// Imports notes from Bear's local SQLite database into Pinkha documents.
    ///
    /// `db_path` — absolute path to Bear's `database.sqlite`, obtained via a
    /// Swift file picker scoped to Bear's group container.
    pub async fn import_from_bear(&self, db_path: String) -> Result<ImportResultFfi, PinkhaError> {
        use crate::extractors::bear::{BearConfig, BearExtractor};
        use crate::extractors::traits::Extractor;
        validate_string(&db_path, "db_path")?;
        let extractor = BearExtractor::new();
        let config = BearConfig { db_path };
        extractor
            .run(config, &self.docs, &self.dbs, &self.folders)
            .await
            .map(ffi_import_result)
            .map_err(extractor_err_to_ffi)
    }

    /// Imports pages from Craft's local `.realm` file into Pinkha documents.
    ///
    /// `db_path` — absolute path to a `*.realm` file inside Craft's container,
    /// obtained via a Swift file picker.  Pinkha reads it in read-only mode.
    pub async fn import_from_craft(&self, db_path: String) -> Result<ImportResultFfi, PinkhaError> {
        use crate::extractors::craft::{CraftConfig, CraftExtractor};
        use crate::extractors::traits::Extractor;
        validate_string(&db_path, "db_path")?;
        let extractor = CraftExtractor::new();
        let config = CraftConfig { db_path };
        extractor
            .run(config, &self.docs, &self.dbs, &self.folders)
            .await
            .map(ffi_import_result)
            .map_err(extractor_err_to_ffi)
    }

    /// `root_dir` — absolute path to the folder containing `.textbundle` packages
    /// exported from Craft ("Export All").
    pub async fn import_from_craft_textbundle(
        &self,
        root_dir: String,
    ) -> Result<ImportResultFfi, PinkhaError> {
        use crate::extractors::craft_textbundle::{
            CraftTextBundleConfig, CraftTextBundleExtractor,
        };
        use crate::extractors::traits::Extractor;
        validate_string(&root_dir, "root_dir")?;
        let extractor = CraftTextBundleExtractor::new();
        let config = CraftTextBundleConfig { root_dir };
        extractor
            .run(config, &self.docs, &self.dbs, &self.folders)
            .await
            .map(ffi_import_result)
            .map_err(extractor_err_to_ffi)
    }

    /// Combines Craft's `.realm` database with a folder of `.textbundle` exports.
    /// `realm_path` — absolute path to the `.realm` file.
    /// `textbundle_root` — absolute path to the folder containing `.textbundle` packages.
    pub async fn import_from_craft_combined(
        &self,
        realm_path: String,
        textbundle_root: String,
    ) -> Result<ImportResultFfi, PinkhaError> {
        use crate::extractors::craft_combined::{CraftCombinedConfig, CraftCombinedExtractor};
        validate_string(&realm_path, "realm_path")?;
        validate_string(&textbundle_root, "textbundle_root")?;
        let extractor = CraftCombinedExtractor::new();
        let config = CraftCombinedConfig {
            realm_path,
            textbundle_root,
        };
        extractor
            .run_detailed(config, &self.docs, &self.dbs, &self.folders)
            .await
            .map(|(r, bd)| ImportResultFfi {
                app: r.app.to_string(),
                database_id: String::new(),
                documents: r.documents as u32,
                entries: 0,
                blocks: r.blocks as u32,
                skipped: r.skipped as u32,
                matched_textbundle: bd.matched_textbundle as u32,
                realm_fallback: bd.realm_fallback as u32,
                textbundle_only: bd.textbundle_only as u32,
            })
            .map_err(extractor_err_to_ffi)
    }
}

fn ffi_import_result(r: crate::extractors::ImportResult) -> ImportResultFfi {
    ImportResultFfi {
        app: r.app.to_string(),
        database_id: r.database_id.map(|id| id.to_string()).unwrap_or_default(),
        documents: r.documents as u32,
        entries: r.entries as u32,
        blocks: r.blocks as u32,
        skipped: r.skipped as u32,
        matched_textbundle: 0,
        realm_fallback: 0,
        textbundle_only: 0,
    }
}

fn extractor_err_to_ffi(e: crate::extractors::ExtractorError) -> PinkhaError {
    match e {
        crate::extractors::ExtractorError::Http { status, message } => PinkhaError::Storage {
            detail: format!("HTTP {status}: {message}"),
        },
        crate::extractors::ExtractorError::Auth(msg) => {
            PinkhaError::InvalidOperation { detail: msg }
        }
        crate::extractors::ExtractorError::Parse(msg) => PinkhaError::Storage { detail: msg },
        crate::extractors::ExtractorError::Storage(e) => e.into(),
    }
}
