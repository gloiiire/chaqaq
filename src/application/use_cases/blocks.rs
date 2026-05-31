use crate::application::error::PinkhaError;
use crate::application::repository::DocumentRepository;
use crate::application::use_cases::document::find_block_mut;
use crate::domain::document::{Block, BlockContent, Document};
use uuid::Uuid;

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

// ── Internal helpers ──────────────────────────────────────────────────────────

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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::application::error::PinkhaError;
    use crate::domain::document::{Document, DocumentMeta};
    use crate::domain::document::InlineText;
    use std::cell::RefCell;
    use std::collections::HashMap;
    use uuid::Uuid;

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
}
