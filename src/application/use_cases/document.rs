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

/// Loads a full document by ID.
pub fn get_document(uow: &dyn UnitOfWork, id: Uuid) -> Result<Document, PinkhaError> {
    uow.documents().load(id)
}

/// Returns lightweight metadata for all documents (no blocks loaded).
pub fn list_documents(uow: &dyn UnitOfWork) -> Result<Vec<DocumentMeta>, PinkhaError> {
    uow.documents().list()
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

pub(super) fn find_block_mut(blocks: &mut Vec<Block>, id: Uuid) -> Option<&mut Block> {
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
