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

/// Sets (or clears with `None`) the block-level text color and persists.
///
/// The color is a color name (e.g. `"red"`, `"blue"`) and applies at render
/// time to every span that has no inline color of its own — inline colors
/// always win over the block color.
pub fn set_block_color(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    block_id: Uuid,
    color: Option<String>,
) -> Result<(), PinkhaError> {
    let mut doc = repo.load(doc_id)?;
    let block =
        find_block_mut(&mut doc.blocks, block_id).ok_or(PinkhaError::NotFound(block_id))?;
    block.color = color;
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

/// Indents a block: moves it under the previous sibling at the same level
/// (becomes the last child of that sibling).
///
/// Returns `InvalidOperation` when the block is the first in its sibling list
/// (no previous sibling to attach to) — there's nothing meaningful to indent
/// it under. Returns `NotFound` if the block is unknown.
pub fn indent_block(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    block_id: Uuid,
) -> Result<(), PinkhaError> {
    let mut doc = repo.load(doc_id)?;
    indent_in_siblings(&mut doc.blocks, block_id)?;
    repo.save(&doc)
}

/// Walks the tree looking for `block_id` among siblings (recursively) and
/// performs the indent in place. Returns `Ok` on success, `NotFound` if not
/// in this subtree, or `InvalidOperation` when `block_id` is the first child
/// of its container.
fn indent_in_siblings(
    siblings: &mut Vec<Block>,
    block_id: Uuid,
) -> Result<(), PinkhaError> {
    if let Some(pos) = siblings.iter().position(|b| b.id == block_id) {
        if pos == 0 {
            return Err(PinkhaError::InvalidOperation(
                "cannot indent the first block of its level".to_string(),
            ));
        }
        let block = siblings.remove(pos);
        siblings[pos - 1].children.push(block);
        return Ok(());
    }
    for sibling in siblings.iter_mut() {
        match indent_in_siblings(&mut sibling.children, block_id) {
            Ok(()) => return Ok(()),
            Err(PinkhaError::NotFound(_)) => continue,
            Err(e) => return Err(e),
        }
    }
    Err(PinkhaError::NotFound(block_id))
}

/// Outdents a block: moves it out of its current parent to the grandparent
/// level, inserted right after the former parent (preserving reading order).
///
/// Returns `InvalidOperation` when the block is already at the document root
/// (nothing to outdent into). Returns `NotFound` if the block is unknown.
pub fn outdent_block(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    block_id: Uuid,
) -> Result<(), PinkhaError> {
    let mut doc = repo.load(doc_id)?;
    if doc.blocks.iter().any(|b| b.id == block_id) {
        return Err(PinkhaError::InvalidOperation(
            "block is already at the root level".to_string(),
        ));
    }
    if !outdent_in_tree(&mut doc.blocks, block_id) {
        return Err(PinkhaError::NotFound(block_id));
    }
    repo.save(&doc)
}

/// Recursively searches for `block_id` among the children of any block in
/// `siblings`. When found, removes it from that child list and reinserts it
/// in `siblings` directly after the block that owned it. Returns `true` if
/// the operation succeeded somewhere in this subtree.
fn outdent_in_tree(siblings: &mut Vec<Block>, block_id: Uuid) -> bool {
    for parent_pos in 0..siblings.len() {
        if let Some(child_pos) = siblings[parent_pos]
            .children
            .iter()
            .position(|c| c.id == block_id)
        {
            let block = siblings[parent_pos].children.remove(child_pos);
            siblings.insert(parent_pos + 1, block);
            return true;
        }
        if outdent_in_tree(&mut siblings[parent_pos].children, block_id) {
            return true;
        }
    }
    false
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
        fn move_to_folder(&self, _doc_id: Uuid, _folder_id: Option<Uuid>) -> Result<(), PinkhaError> { Ok(()) }
        fn list_by_folder(&self, _folder_id: Option<Uuid>) -> Result<Vec<DocumentMeta>, PinkhaError> { self.list() }
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

    #[test]
    fn test_set_block_color_set_and_clear() {
        let repo = MockRepo::new();
        let mut doc = Document::new(inline("Test"));
        let block = text_block("bloc");
        let block_id = block.id;
        doc.blocks.push(block);
        repo.save(&doc).unwrap();

        set_block_color(&repo, doc.id, block_id, Some("red".into())).unwrap();
        let loaded = repo.load(doc.id).unwrap();
        assert_eq!(loaded.blocks[0].color.as_deref(), Some("red"));

        set_block_color(&repo, doc.id, block_id, None).unwrap();
        let loaded = repo.load(doc.id).unwrap();
        assert!(loaded.blocks[0].color.is_none());
    }

    #[test]
    fn test_set_block_color_on_nested_child() {
        let repo = MockRepo::new();
        let mut doc = Document::new(inline("Test"));
        let mut parent = text_block("parent");
        let child = text_block("enfant");
        let child_id = child.id;
        parent.children.push(child);
        doc.blocks.push(parent);
        repo.save(&doc).unwrap();

        set_block_color(&repo, doc.id, child_id, Some("blue".into())).unwrap();
        let loaded = repo.load(doc.id).unwrap();
        assert_eq!(loaded.blocks[0].children[0].color.as_deref(), Some("blue"));
        // The parent itself is untouched.
        assert!(loaded.blocks[0].color.is_none());
    }

    #[test]
    fn test_set_block_color_unknown_block_returns_not_found() {
        let repo = MockRepo::new();
        let doc = Document::new(inline("Test"));
        repo.save(&doc).unwrap();
        let unknown = Uuid::new_v4();
        let res = set_block_color(&repo, doc.id, unknown, Some("red".into()));
        assert!(matches!(res, Err(PinkhaError::NotFound(_))));
    }

    // ── indent / outdent ──────────────────────────────────────────────────

    #[test]
    fn test_indent_moves_block_under_previous_sibling() {
        let repo = MockRepo::new();
        let mut doc = Document::new(inline("Test"));
        let a = text_block("A");
        let b = text_block("B");
        let b_id = b.id;
        doc.blocks.push(a);
        doc.blocks.push(b);
        repo.save(&doc).unwrap();

        indent_block(&repo, doc.id, b_id).unwrap();

        let loaded = repo.load(doc.id).unwrap();
        assert_eq!(loaded.blocks.len(), 1);
        assert_eq!(loaded.blocks[0].children.len(), 1);
        assert_eq!(loaded.blocks[0].children[0].id, b_id);
    }

    #[test]
    fn test_indent_first_block_fails() {
        let repo = MockRepo::new();
        let mut doc = Document::new(inline("Test"));
        let a = text_block("A");
        let a_id = a.id;
        doc.blocks.push(a);
        repo.save(&doc).unwrap();

        let res = indent_block(&repo, doc.id, a_id);
        assert!(matches!(res, Err(PinkhaError::InvalidOperation(_))));
    }

    #[test]
    fn test_indent_works_inside_nested_subtree() {
        // [parent]
        //   ├─ child1
        //   └─ child2  ← indent child2 under child1
        let repo = MockRepo::new();
        let mut doc = Document::new(inline("Test"));
        let mut parent = text_block("parent");
        let child1 = text_block("child1");
        let child2 = text_block("child2");
        let child2_id = child2.id;
        parent.children.push(child1);
        parent.children.push(child2);
        doc.blocks.push(parent);
        repo.save(&doc).unwrap();

        indent_block(&repo, doc.id, child2_id).unwrap();

        let loaded = repo.load(doc.id).unwrap();
        assert_eq!(loaded.blocks[0].children.len(), 1);
        assert_eq!(loaded.blocks[0].children[0].children[0].id, child2_id);
    }

    #[test]
    fn test_outdent_moves_block_to_grandparent_after_parent() {
        // parent
        //   └─ child  ← outdent
        // → parent, child (sibling, right after)
        let repo = MockRepo::new();
        let mut doc = Document::new(inline("Test"));
        let mut parent = text_block("parent");
        let child = text_block("child");
        let child_id = child.id;
        parent.children.push(child);
        doc.blocks.push(parent);
        repo.save(&doc).unwrap();

        outdent_block(&repo, doc.id, child_id).unwrap();

        let loaded = repo.load(doc.id).unwrap();
        assert_eq!(loaded.blocks.len(), 2);
        assert!(loaded.blocks[0].children.is_empty());
        assert_eq!(loaded.blocks[1].id, child_id);
    }

    #[test]
    fn test_outdent_root_block_fails() {
        let repo = MockRepo::new();
        let mut doc = Document::new(inline("Test"));
        let a = text_block("A");
        let a_id = a.id;
        doc.blocks.push(a);
        repo.save(&doc).unwrap();

        let res = outdent_block(&repo, doc.id, a_id);
        assert!(matches!(res, Err(PinkhaError::InvalidOperation(_))));
    }

    #[test]
    fn test_outdent_keeps_reading_order_with_sibling_after_parent() {
        // root
        //   ├─ parent
        //   │    └─ child  ← outdent
        //   └─ z
        // → root.children = [parent, child, z]
        let repo = MockRepo::new();
        let mut doc = Document::new(inline("Test"));
        let mut parent = text_block("parent");
        let child = text_block("child");
        let child_id = child.id;
        parent.children.push(child);
        let z = text_block("z");
        let z_id = z.id;
        doc.blocks.push(parent);
        doc.blocks.push(z);
        repo.save(&doc).unwrap();

        outdent_block(&repo, doc.id, child_id).unwrap();

        let loaded = repo.load(doc.id).unwrap();
        assert_eq!(loaded.blocks.len(), 3);
        assert_eq!(loaded.blocks[1].id, child_id);
        assert_eq!(loaded.blocks[2].id, z_id);
    }
}
