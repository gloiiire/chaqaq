use crate::application::error::PinkhaError;
use crate::application::unit_of_work::UnitOfWork;
use crate::domain::document::{Block, BlockContent, Document, DocumentMeta, InlineText};
use crate::domain::editor::EditorState;
use crate::domain::parser::parse_inline;
use uuid::Uuid;

/// Creates a new document with a parsed inline title and persists it.
pub fn create_document(uow: &dyn UnitOfWork, title: &str) -> Result<Document, PinkhaError> {
    let doc = Document::new(parse_inline(title));
    uow.documents().save(&doc)?;
    Ok(doc)
}

/// Variant of `create_document` that pins the doc's `created_at` to a
/// specific timestamp (RFC 3339). Used by importers (Notion / Bear /
/// Craft) so the imported note carries the original platform's
/// creation date through to its SQLite row — `created_at` is otherwise
/// set to `now()` at first INSERT and immutable afterwards.
pub fn create_document_with_created_at(
    uow: &dyn UnitOfWork,
    title: &str,
    created_at: String,
) -> Result<Document, PinkhaError> {
    let mut doc = Document::new(parse_inline(title));
    doc.created_at = Some(created_at);
    uow.documents().save(&doc)?;
    Ok(doc)
}

/// Loads a full document by ID.
pub fn get_document(uow: &dyn UnitOfWork, id: Uuid) -> Result<Document, PinkhaError> {
    uow.documents().load(id)
}

/// Returns lightweight metadata for all documents (no blocks loaded).
pub fn list_documents(uow: &dyn UnitOfWork) -> Result<Vec<DocumentMeta>, PinkhaError> {
    uow.documents().list()
}

/// Returns lightweight metadata for a single document. Callers that only
/// need the title / icon / cover should prefer this over [`get_document`]
/// so the block tree never crosses the boundary.
pub fn get_document_meta(uow: &dyn UnitOfWork, id: Uuid) -> Result<DocumentMeta, PinkhaError> {
    let doc = uow.documents().load(id)?;
    Ok(DocumentMeta::from(&doc))
}

/// Soft-deletes a document by ID — recoverable via [`restore_document`].
pub fn delete_document(uow: &dyn UnitOfWork, doc_id: Uuid) -> Result<(), PinkhaError> {
    uow.documents().delete(doc_id)
}

/// Lists soft-deleted documents (newest-deleted first) — what the trash UI shows.
pub fn list_deleted_documents(uow: &dyn UnitOfWork) -> Result<Vec<DocumentMeta>, PinkhaError> {
    uow.documents().list_deleted()
}

/// Restores a soft-deleted document (clears its `deleted_at`).
pub fn restore_document(uow: &dyn UnitOfWork, doc_id: Uuid) -> Result<(), PinkhaError> {
    uow.documents().restore(doc_id)
}

/// Permanently deletes a soft-deleted document (hard delete).
pub fn purge_document(uow: &dyn UnitOfWork, doc_id: Uuid) -> Result<(), PinkhaError> {
    uow.documents().purge(doc_id)
}

/// Updates the document title (parsed as inline rich text) and persists.
pub fn update_document_title(
    uow: &dyn UnitOfWork,
    doc_id: Uuid,
    new_title: &str,
) -> Result<(), PinkhaError> {
    let repo = uow.documents();
    let mut doc = repo.load(doc_id)?;
    doc.title = parse_inline(new_title);
    repo.save(&doc)
}

/// Updates the document cover and persists.
pub fn update_document_cover(
    uow: &dyn UnitOfWork,
    doc_id: Uuid,
    cover: Option<String>,
) -> Result<(), PinkhaError> {
    let repo = uow.documents();
    let mut doc = repo.load(doc_id)?;
    doc.cover = cover;
    repo.save(&doc)
}

/// Updates the document icon (small visual identifier — emoji or image URL/
/// filename) and persists.
pub fn update_document_icon(
    uow: &dyn UnitOfWork,
    doc_id: Uuid,
    icon: Option<String>,
) -> Result<(), PinkhaError> {
    let repo = uow.documents();
    let mut doc = repo.load(doc_id)?;
    doc.icon = icon;
    repo.save(&doc)
}

/// Sets (or clears with `None`) the per-document accent color name
/// and persists. When `Some`, the editor renders its chrome with this
/// color instead of the app-wide accent from settings; `None` falls
/// back to the global accent.
pub fn update_document_accent_color(
    uow: &dyn UnitOfWork,
    doc_id: Uuid,
    accent_color: Option<String>,
) -> Result<(), PinkhaError> {
    let repo = uow.documents();
    let mut doc = repo.load(doc_id)?;
    doc.accent_color = accent_color;
    repo.save(&doc)
}

/// Sets (or clears with `None`) the per-document writing direction.
/// Values: `"ltr"`, `"rtl"`, or `None` to let the system locale
/// decide. Acts as the default direction for every block; individual
/// blocks can still override via `set_block_text_direction`.
pub fn update_document_text_direction(
    uow: &dyn UnitOfWork,
    doc_id: Uuid,
    text_direction: Option<String>,
) -> Result<(), PinkhaError> {
    let repo = uow.documents();
    let mut doc = repo.load(doc_id)?;
    doc.text_direction = text_direction;
    repo.save(&doc)
}

/// Sets (or clears with `None`) the per-document theme.
/// Values: `"original"`, `"tranquille"`, `"papier"`, `"gras"`,
/// `"calme"`, `"attention"`, or `None` to inherit from
/// `AppSettings.theme`. The editor maps the name to a palette
/// (background, text color, bold) at render time.
pub fn update_document_theme(
    uow: &dyn UnitOfWork,
    doc_id: Uuid,
    theme: Option<String>,
) -> Result<(), PinkhaError> {
    let repo = uow.documents();
    let mut doc = repo.load(doc_id)?;
    doc.theme = theme;
    repo.save(&doc)
}

/// Toggles the read-only lock on a document and persists. Imports default
/// new documents to `locked = true` so the user reads the extracted content
/// before editing it.
pub fn update_document_locked(
    uow: &dyn UnitOfWork,
    doc_id: Uuid,
    locked: bool,
) -> Result<(), PinkhaError> {
    let repo = uow.documents();
    let mut doc = repo.load(doc_id)?;
    doc.locked = locked;
    repo.save(&doc)
}

/// Overrides the document's user-editable `published_at` timestamp.
/// Empty string resets the doc to the default "follow `created_at`"
/// behaviour. Mirrors `update_entry_published_at` on Entry.
pub fn update_document_published_at(
    uow: &dyn UnitOfWork,
    doc_id: Uuid,
    new_published_at: String,
) -> Result<(), PinkhaError> {
    let repo = uow.documents();
    let mut doc = repo.load(doc_id)?;
    doc.published_at = new_published_at;
    repo.save(&doc)
}

/// Moves a document to a folder (or to the root when `folder_id` is `None`).
pub fn move_document_to_folder(
    uow: &dyn UnitOfWork,
    doc_id: Uuid,
    folder_id: Option<Uuid>,
) -> Result<(), PinkhaError> {
    uow.documents().move_to_folder(doc_id, folder_id)
}

/// Returns lightweight metadata for all documents in the given folder (or root).
pub fn list_documents_in_folder(
    uow: &dyn UnitOfWork,
    folder_id: Option<Uuid>,
) -> Result<Vec<DocumentMeta>, PinkhaError> {
    uow.documents().list_by_folder(folder_id)
}

/// Sets the parent document for Notion-style page-in-page hierarchy. Pass
/// `None` to promote `doc_id` back to root. Rejects cycles (refuses to make
/// `doc_id` a descendant of itself) so the hierarchy stays acyclic — without
/// this, the breadcrumbs would loop and a depth-first render would recurse
/// forever.
pub fn update_document_parent(
    uow: &dyn UnitOfWork,
    doc_id: Uuid,
    new_parent_doc_id: Option<Uuid>,
) -> Result<(), PinkhaError> {
    if let Some(new_parent) = new_parent_doc_id {
        if new_parent == doc_id {
            return Err(PinkhaError::InvalidOperation(
                "a document cannot be its own parent".into(),
            ));
        }
        // Walk up from the prospective new parent: if we ever reach `doc_id`,
        // the move would create a cycle.
        let repo = uow.documents();
        let mut cursor = Some(new_parent);
        while let Some(id) = cursor {
            let ancestor = repo.load(id)?;
            if ancestor.parent_doc_id == Some(doc_id) {
                return Err(PinkhaError::InvalidOperation(
                    "moving here would create a parent/child cycle".into(),
                ));
            }
            cursor = ancestor.parent_doc_id;
        }
    }
    let repo = uow.documents();
    let mut doc = repo.load(doc_id)?;
    doc.parent_doc_id = new_parent_doc_id;
    repo.save(&doc)
}

/// Returns lightweight metadata for documents at the root of the page tree
/// (no parent document). Drives the home view, which only surfaces top-level
/// pages — child pages are reached by tapping their parent.
pub fn list_root_documents(uow: &dyn UnitOfWork) -> Result<Vec<DocumentMeta>, PinkhaError> {
    Ok(uow
        .documents()
        .list()?
        .into_iter()
        .filter(|m| m.parent_doc_id.is_none())
        .collect())
}

/// Returns lightweight metadata for the direct children of `parent_doc_id`.
/// Used by the breadcrumbs / child-page section of the document view.
pub fn list_child_documents(
    uow: &dyn UnitOfWork,
    parent_doc_id: Uuid,
) -> Result<Vec<DocumentMeta>, PinkhaError> {
    Ok(uow
        .documents()
        .list()?
        .into_iter()
        .filter(|m| m.parent_doc_id == Some(parent_doc_id))
        .collect())
}

/// Applies the editor state to a text-bearing block and persists the document.
///
/// Returns `InvalidOperation` when the target block does not carry editable text
/// (e.g. `Divider`, `Database`).
pub fn save_edited_block(
    uow: &dyn UnitOfWork,
    doc_id: Uuid,
    block_id: Uuid,
    editor_state: &EditorState,
) -> Result<(), PinkhaError> {
    let repo = uow.documents();
    let mut doc = repo.load(doc_id)?;
    let inlines: Vec<InlineText> = Vec::from(&editor_state.text);
    let block = find_block_mut(&mut doc.blocks, block_id).ok_or(PinkhaError::NotFound(block_id))?;

    block.content = match &block.content {
        BlockContent::Text(_) => BlockContent::Text(inlines),
        BlockContent::Heading { level, .. } => BlockContent::Heading {
            text: inlines,
            level: *level,
        },
        BlockContent::Quote { icon, .. } => BlockContent::Quote {
            icon: icon.clone(),
            text: inlines,
        },
        BlockContent::Todo { done, .. } => BlockContent::Todo {
            text: inlines,
            done: *done,
        },
        _ => {
            return Err(PinkhaError::InvalidOperation(format!(
                "block {block_id} does not contain editable text"
            )));
        }
    };
    repo.save(&doc)
}

// ── Internal tree helpers (shared with blocks module) ─────────────────────────

pub(super) fn find_block_mut(blocks: &mut [Block], id: Uuid) -> Option<&mut Block> {
    // first pass: search at the current level
    if let Some(pos) = blocks.iter().position(|b| b.id == id) {
        return Some(&mut blocks[pos]);
    }
    // second pass: recurse into children
    for block in blocks.iter_mut() {
        if let Some(found) = find_block_mut(&mut block.children, id) {
            return Some(found);
        }
    }
    None
}
