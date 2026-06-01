use crate::application::error::PinkhaError;
use crate::application::repository::DocumentRepository;
use crate::domain::document::{Block, BlockContent, Document, DocumentMeta, InlineText};
use crate::domain::editor::EditorState;
use crate::domain::parser::parse_inline;
use uuid::Uuid;

/// Creates a new document with a parsed inline title and persists it.
pub fn create_document(repo: &dyn DocumentRepository, title: &str) -> Result<Document, PinkhaError> {
    let doc = Document::new(parse_inline(title));
    repo.save(&doc)?;
    Ok(doc)
}

/// Loads a full document by ID.
pub fn get_document(repo: &dyn DocumentRepository, id: Uuid) -> Result<Document, PinkhaError> {
    repo.load(id)
}

/// Returns lightweight metadata for all documents (no blocks loaded).
pub fn list_documents(repo: &dyn DocumentRepository) -> Result<Vec<DocumentMeta>, PinkhaError> {
    repo.list()
}

/// Deletes a document by ID.
pub fn delete_document(repo: &dyn DocumentRepository, doc_id: Uuid) -> Result<(), PinkhaError> {
    repo.delete(doc_id)
}

/// Updates the document title (parsed as inline rich text) and persists.
pub fn update_document_title(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    new_title: &str,
) -> Result<(), PinkhaError> {
    let mut doc = repo.load(doc_id)?;
    doc.title = parse_inline(new_title);
    repo.save(&doc)
}

/// Updates the document cover and persists.
pub fn update_document_cover(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    cover: Option<String>,
) -> Result<(), PinkhaError> {
    let mut doc = repo.load(doc_id)?;
    doc.cover = cover;
    repo.save(&doc)
}

/// Moves a document to a folder (or to the root when `folder_id` is `None`).
pub fn move_document_to_folder(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    folder_id: Option<Uuid>,
) -> Result<(), PinkhaError> {
    repo.move_to_folder(doc_id, folder_id)
}

/// Returns lightweight metadata for all documents in the given folder (or root).
pub fn list_documents_in_folder(
    repo: &dyn DocumentRepository,
    folder_id: Option<Uuid>,
) -> Result<Vec<DocumentMeta>, PinkhaError> {
    repo.list_by_folder(folder_id)
}

/// Applies the editor state to a text-bearing block and persists the document.
///
/// Returns `InvalidOperation` when the target block does not carry editable text
/// (e.g. `Divider`, `Database`).
pub fn save_edited_block(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    block_id: Uuid,
    editor_state: &EditorState,
) -> Result<(), PinkhaError> {
    let mut doc = repo.load(doc_id)?;
    let inlines: Vec<InlineText> = Vec::from(&editor_state.text);
    let block =
        find_block_mut(&mut doc.blocks, block_id).ok_or(PinkhaError::NotFound(block_id))?;

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
