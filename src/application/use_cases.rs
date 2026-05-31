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

/// Appends a new block to the document's top-level block list and persists.
pub fn add_block(
    repo: &dyn DocumentRepository,
    id: Uuid,
    content: BlockContent,
) -> Result<Document, PinkhaError> {
    let mut doc = repo.load(id)?;
    doc.add_block(content);
    repo.save(&doc)?;
    Ok(doc)
}

// ── Document metadata ─────────────────────────────────────────────────────────

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

// ── EditorState → Block bridge ────────────────────────────────────────────────

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

// ── Block management ──────────────────────────────────────────────────────────

/// Replaces the content of an existing block (e.g. toggle todo, type conversion) and persists.
pub fn update_block(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    block_id: Uuid,
    new_content: BlockContent,
) -> Result<(), PinkhaError> {
    let mut doc = repo.load(doc_id)?;
    let block =
        find_block_mut(&mut doc.blocks, block_id).ok_or(PinkhaError::NotFound(block_id))?;
    block.content = new_content;
    repo.save(&doc)
}

/// Deletes a block (and all its descendants) from the document tree and persists.
pub fn delete_block(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    block_id: Uuid,
) -> Result<(), PinkhaError> {
    let mut doc = repo.load(doc_id)?;
    if !delete_from_tree(&mut doc.blocks, block_id) {
        return Err(PinkhaError::NotFound(block_id));
    }
    repo.save(&doc)
}

/// Reorders the top-level blocks according to the supplied list of UUIDs.
///
/// Blocks not present in `order` are preserved and appended at the end.
pub fn reorder_blocks(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    order: Vec<Uuid>,
) -> Result<(), PinkhaError> {
    let mut doc = repo.load(doc_id)?;
    let mut reordered: Vec<Block> = Vec::with_capacity(doc.blocks.len());
    for id in &order {
        if let Some(pos) = doc.blocks.iter().position(|b| b.id == *id) {
            reordered.push(doc.blocks.remove(pos));
        }
    }
    reordered.extend(doc.blocks);
    doc.blocks = reordered;
    repo.save(&doc)
}

/// Adds a block as a direct child of an existing block (nested blocks) and persists.
pub fn add_child_block(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    parent_id: Uuid,
    content: BlockContent,
) -> Result<Block, PinkhaError> {
    let mut doc = repo.load(doc_id)?;
    let parent =
        find_block_mut(&mut doc.blocks, parent_id).ok_or(PinkhaError::NotFound(parent_id))?;
    let child = Block::new(content);
    parent.children.push(child.clone());
    repo.save(&doc)?;
    Ok(child)
}

// ── Search ────────────────────────────────────────────────────────────────────

/// Case-insensitive search across document titles.
pub fn search_documents(
    repo: &dyn DocumentRepository,
    query: &str,
) -> Result<Vec<DocumentMeta>, PinkhaError> {
    let q = query.to_lowercase();
    Ok(repo
        .list()?
        .into_iter()
        .filter(|m| {
            m.title
                .iter()
                .any(|t| t.content.to_lowercase().contains(&q))
        })
        .collect())
}

// ── Internal helpers ──────────────────────────────────────────────────────────

fn find_block_mut(blocks: &mut Vec<Block>, id: Uuid) -> Option<&mut Block> {
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

fn delete_from_tree(blocks: &mut Vec<Block>, id: Uuid) -> bool {
    let before = blocks.len();
    blocks.retain(|b| b.id != id);
    if blocks.len() < before {
        return true;
    }
    blocks
        .iter_mut()
        .any(|b| delete_from_tree(&mut b.children, id))
}

fn extract_block(blocks: &mut Vec<Block>, id: Uuid) -> Option<Block> {
    if let Some(pos) = blocks.iter().position(|b| b.id == id) {
        return Some(blocks.remove(pos));
    }
    for block in blocks.iter_mut() {
        if let Some(found) = extract_block(&mut block.children, id) {
            return Some(found);
        }
    }
    None
}

fn blocks_contain(blocks: &[Block], query: &str) -> bool {
    blocks.iter().any(|b| block_contains(b, query))
}

fn block_contains(block: &Block, query: &str) -> bool {
    let matches_text = match &block.content {
        BlockContent::Text(inlines)
        | BlockContent::Heading { text: inlines, .. }
        | BlockContent::Quote { text: inlines, .. }
        | BlockContent::Todo { text: inlines, .. } => inlines
            .iter()
            .any(|i| i.content.to_lowercase().contains(query)),
        _ => false,
    };
    matches_text || blocks_contain(&block.children, query)
}

// ── Nested blocks — reordering and moving ────────────────────────────────────

/// Reorders the children of a parent block according to the supplied list of UUIDs.
///
/// Children not present in `order` are preserved and appended at the end.
pub fn reorder_child_blocks(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    parent_id: Uuid,
    order: Vec<Uuid>,
) -> Result<(), PinkhaError> {
    let mut doc = repo.load(doc_id)?;
    let parent =
        find_block_mut(&mut doc.blocks, parent_id).ok_or(PinkhaError::NotFound(parent_id))?;
    let mut reordered: Vec<Block> = Vec::with_capacity(parent.children.len());
    for id in &order {
        if let Some(pos) = parent.children.iter().position(|b| b.id == *id) {
            reordered.push(parent.children.remove(pos));
        }
    }
    reordered.extend(parent.children.drain(..));
    parent.children = reordered;
    repo.save(&doc)
}

/// Moves a block to a new parent (`None` = document root).
///
/// Returns `InvalidOperation` when `block_id == new_parent_id`.
pub fn move_block(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    block_id: Uuid,
    new_parent_id: Option<Uuid>,
) -> Result<(), PinkhaError> {
    if new_parent_id == Some(block_id) {
        return Err(PinkhaError::InvalidOperation(
            "cannot move a block into itself".to_string(),
        ));
    }
    let mut doc = repo.load(doc_id)?;
    let block = extract_block(&mut doc.blocks, block_id).ok_or(PinkhaError::NotFound(block_id))?;
    match new_parent_id {
        None => doc.blocks.push(block),
        Some(parent_id) => {
            let parent = find_block_mut(&mut doc.blocks, parent_id)
                .ok_or(PinkhaError::NotFound(parent_id))?;
            parent.children.push(block);
        }
    }
    repo.save(&doc)
}

// ── Full-text search ──────────────────────────────────────────────────────────

/// Case-insensitive full-text search across the block content of all documents.
///
/// Returns the metadata of documents that contain at least one matching block.
pub fn search_in_blocks(
    repo: &dyn DocumentRepository,
    query: &str,
) -> Result<Vec<DocumentMeta>, PinkhaError> {
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::document::InlineText;
    use std::cell::RefCell;
    use std::collections::HashMap;

    struct MockRepo {
        docs: RefCell<HashMap<Uuid, Document>>,
    }

    impl MockRepo {
        fn new() -> Self {
            Self {
                docs: RefCell::new(HashMap::new()),
            }
        }
    }

    impl DocumentRepository for MockRepo {
        fn save(&self, doc: &Document) -> Result<(), PinkhaError> {
            self.docs.borrow_mut().insert(doc.id, doc.clone());
            Ok(())
        }
        fn load(&self, id: Uuid) -> Result<Document, PinkhaError> {
            self.docs
                .borrow()
                .get(&id)
                .cloned()
                .ok_or(PinkhaError::NotFound(id))
        }
        fn list(&self) -> Result<Vec<DocumentMeta>, PinkhaError> {
            Ok(self
                .docs
                .borrow()
                .values()
                .map(DocumentMeta::from)
                .collect())
        }
        fn delete(&self, id: Uuid) -> Result<(), PinkhaError> {
            self.docs
                .borrow_mut()
                .remove(&id)
                .map(|_| ())
                .ok_or(PinkhaError::NotFound(id))
        }
    }

    fn inline(s: &str) -> Vec<InlineText> {
        vec![InlineText {
            content: s.to_string(),
            styles: vec![],
        }]
    }

    fn doc_with_blocks(title: &str, blocks: Vec<Block>) -> Document {
        let mut doc = Document::new(inline(title));
        doc.blocks = blocks;
        doc
    }

    fn text_block(s: &str) -> Block {
        Block::new(BlockContent::Text(inline(s)))
    }

    #[test]
    fn test_reorder_child_blocks() {
        let repo = MockRepo::new();
        let mut doc = Document::new(inline("Test"));
        let parent = Block::new(BlockContent::Text(inline("parent")));
        let parent_id = parent.id;
        doc.blocks.push(parent);
        repo.save(&doc).unwrap();

        let child_a =
            add_child_block(&repo, doc.id, parent_id, BlockContent::Text(inline("A"))).unwrap();
        let child_b =
            add_child_block(&repo, doc.id, parent_id, BlockContent::Text(inline("B"))).unwrap();
        let child_c =
            add_child_block(&repo, doc.id, parent_id, BlockContent::Text(inline("C"))).unwrap();

        reorder_child_blocks(
            &repo,
            doc.id,
            parent_id,
            vec![child_c.id, child_a.id, child_b.id],
        )
        .unwrap();

        let doc = repo.load(doc.id).unwrap();
        let children = &doc.blocks[0].children;
        assert_eq!(children[0].id, child_c.id);
        assert_eq!(children[1].id, child_a.id);
        assert_eq!(children[2].id, child_b.id);
    }

    #[test]
    fn test_move_block_racine_vers_enfant() {
        let repo = MockRepo::new();
        let mut doc = Document::new(inline("Test"));
        let parent = text_block("parent");
        let child = text_block("à déplacer");
        let parent_id = parent.id;
        let child_id = child.id;
        doc.blocks.push(parent);
        doc.blocks.push(child);
        repo.save(&doc).unwrap();

        move_block(&repo, doc.id, child_id, Some(parent_id)).unwrap();

        let doc = repo.load(doc.id).unwrap();
        assert_eq!(doc.blocks.len(), 1);
        assert_eq!(doc.blocks[0].children.len(), 1);
        assert_eq!(doc.blocks[0].children[0].id, child_id);
    }

    #[test]
    fn test_move_block_enfant_vers_racine() {
        let repo = MockRepo::new();
        let mut doc = Document::new(inline("Test"));
        let mut parent = text_block("parent");
        let child = text_block("enfant");
        let child_id = child.id;
        parent.children.push(child);
        doc.blocks.push(parent);
        repo.save(&doc).unwrap();

        move_block(&repo, doc.id, child_id, None).unwrap();

        let doc = repo.load(doc.id).unwrap();
        assert_eq!(doc.blocks.len(), 2);
        assert!(doc.blocks[0].children.is_empty());
        assert_eq!(doc.blocks[1].id, child_id);
    }

    #[test]
    fn test_move_block_dans_lui_meme_erreur() {
        let repo = MockRepo::new();
        let mut doc = Document::new(inline("Test"));
        let block = text_block("bloc");
        let block_id = block.id;
        doc.blocks.push(block);
        repo.save(&doc).unwrap();

        let res = move_block(&repo, doc.id, block_id, Some(block_id));
        assert!(matches!(res, Err(PinkhaError::InvalidOperation(_))));
    }

    #[test]
    fn test_search_in_blocks_trouve() {
        let repo = MockRepo::new();
        let doc = doc_with_blocks("Doc", vec![text_block("Rust est génial")]);
        repo.save(&doc).unwrap();

        let results = search_in_blocks(&repo, "rust").unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].id, doc.id);
    }

    #[test]
    fn test_search_in_blocks_pas_de_resultat() {
        let repo = MockRepo::new();
        let doc = doc_with_blocks("Doc", vec![text_block("Bonjour monde")]);
        repo.save(&doc).unwrap();

        let results = search_in_blocks(&repo, "flutter").unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_search_in_blocks_enfants() {
        let repo = MockRepo::new();
        let mut parent = text_block("parent");
        parent
            .children
            .push(text_block("texte caché en profondeur"));
        let doc = doc_with_blocks("Doc", vec![parent]);
        repo.save(&doc).unwrap();

        let results = search_in_blocks(&repo, "profondeur").unwrap();
        assert_eq!(results.len(), 1);
    }
}
