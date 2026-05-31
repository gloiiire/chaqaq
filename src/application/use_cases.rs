use crate::application::error::PinkhaError;
use crate::application::repository::DocumentRepository;
use crate::domain::document::{Block, BlockContent, Document, DocumentMeta, InlineText};
use crate::domain::editor::EditorState;
use crate::domain::parser::parse_inline;
use uuid::Uuid;

pub fn create_document(repo: &dyn DocumentRepository, title: &str) -> Result<Document, PinkhaError> {
    let doc = Document::new(parse_inline(title));
    repo.save(&doc)?;
    Ok(doc)
}

pub fn get_document(repo: &dyn DocumentRepository, id: Uuid) -> Result<Document, PinkhaError> {
    repo.load(id)
}

pub fn list_documents(repo: &dyn DocumentRepository) -> Result<Vec<DocumentMeta>, PinkhaError> {
    repo.list()
}

pub fn delete_document(repo: &dyn DocumentRepository, doc_id: Uuid) -> Result<(), PinkhaError> {
    repo.delete(doc_id)
}

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

// ── Métadonnées du document ───────────────────────────────────────────────────

pub fn update_document_title(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    new_title: &str,
) -> Result<(), PinkhaError> {
    let mut doc = repo.load(doc_id)?;
    doc.title = parse_inline(new_title);
    repo.save(&doc)
}

pub fn update_document_cover(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    cover: Option<String>,
) -> Result<(), PinkhaError> {
    let mut doc = repo.load(doc_id)?;
    doc.cover = cover;
    repo.save(&doc)
}

// ── Bridge EditorState → Block ────────────────────────────────────────────────

/// Applique le contenu de l'éditeur sur un bloc textuel et persiste le document.
/// Retourne InvalidOperation si le bloc ne porte pas de texte (Divider, Database…).
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
                "le bloc {block_id} ne contient pas de texte éditable"
            )));
        }
    };
    repo.save(&doc)
}

// ── Gestion des blocs ─────────────────────────────────────────────────────────

/// Remplace le contenu d'un bloc existant (toggle todo, changement de type…).
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

/// Supprime un bloc (et ses enfants) dans l'arbre du document.
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

/// Réordonne les blocs racine selon la liste d'UUIDs fournie.
/// Les blocs absents de la liste sont conservés et placés à la fin.
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

/// Ajoute un bloc comme enfant direct d'un bloc existant (blocs imbriqués).
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

// ── Recherche ─────────────────────────────────────────────────────────────────

/// Recherche insensible à la casse dans les titles de documents.
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

// ── Helpers internes ──────────────────────────────────────────────────────────

fn find_block_mut(blocks: &mut Vec<Block>, id: Uuid) -> Option<&mut Block> {
    // première passe : cherche au niveau courant
    if let Some(pos) = blocks.iter().position(|b| b.id == id) {
        return Some(&mut blocks[pos]);
    }
    // deuxième passe : récursion dans les enfants
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

// ── Blocs imbriqués — réordonnement et déplacement ───────────────────────────

/// Réordonne les blocs enfants d'un bloc parent selon la liste d'UUIDs fournie.
/// Les enfants absents de la liste sont conservés et placés à la fin.
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

/// Déplace un bloc vers un nouveau parent (None = racine du document).
/// Retourne InvalidOperation si block_id == new_parent_id.
pub fn move_block(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    block_id: Uuid,
    new_parent_id: Option<Uuid>,
) -> Result<(), PinkhaError> {
    if new_parent_id == Some(block_id) {
        return Err(PinkhaError::InvalidOperation(
            "impossible de déplacer un bloc dans lui-même".to_string(),
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

// ── Recherche plein texte ─────────────────────────────────────────────────────

/// Recherche insensible à la casse dans le contenu textuel des blocs de tous les documents.
/// Retourne les métadonnées des documents qui contiennent au moins un bloc correspondant.
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
