use crate::application::error::ChaqaqError;
use crate::application::repository::DocumentRepository;
use crate::domain::document::{Block, BlockContent, Document, DocumentMeta, InlineText};
use crate::domain::editor::EditorState;
use crate::domain::parser::parse_inline;
use uuid::Uuid;

pub fn create_document(repo: &dyn DocumentRepository, title: &str) -> Result<Document, ChaqaqError> {
    let doc = Document::new(parse_inline(title));
    repo.save(&doc)?;
    Ok(doc)
}

pub fn get_document(repo: &dyn DocumentRepository, id: Uuid) -> Result<Document, ChaqaqError> {
    repo.load(id)
}

pub fn list_documents(repo: &dyn DocumentRepository) -> Result<Vec<DocumentMeta>, ChaqaqError> {
    repo.list()
}

pub fn delete_document(repo: &dyn DocumentRepository, doc_id: Uuid) -> Result<(), ChaqaqError> {
    repo.delete(doc_id)
}

pub fn add_block(
    repo: &dyn DocumentRepository,
    id: Uuid,
    content: BlockContent,
) -> Result<Document, ChaqaqError> {
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
) -> Result<(), ChaqaqError> {
    let mut doc = repo.load(doc_id)?;
    doc.title = parse_inline(new_title);
    repo.save(&doc)
}

pub fn update_document_cover(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    cover: Option<String>,
) -> Result<(), ChaqaqError> {
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
    etat: &EditorState,
) -> Result<(), ChaqaqError> {
    let mut doc = repo.load(doc_id)?;
    let inlines: Vec<InlineText> = Vec::from(&etat.texte);
    let bloc =
        find_block_mut(&mut doc.blocks, block_id).ok_or(ChaqaqError::NotFound(block_id))?;

    bloc.content = match &bloc.content {
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
            return Err(ChaqaqError::InvalidOperation(format!(
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
) -> Result<(), ChaqaqError> {
    let mut doc = repo.load(doc_id)?;
    let bloc =
        find_block_mut(&mut doc.blocks, block_id).ok_or(ChaqaqError::NotFound(block_id))?;
    bloc.content = new_content;
    repo.save(&doc)
}

/// Supprime un bloc (et ses enfants) dans l'arbre du document.
pub fn delete_block(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    block_id: Uuid,
) -> Result<(), ChaqaqError> {
    let mut doc = repo.load(doc_id)?;
    if !delete_from_tree(&mut doc.blocks, block_id) {
        return Err(ChaqaqError::NotFound(block_id));
    }
    repo.save(&doc)
}

/// Réordonne les blocs racine selon la liste d'UUIDs fournie.
/// Les blocs absents de la liste sont conservés et placés à la fin.
pub fn reorder_blocks(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    order: Vec<Uuid>,
) -> Result<(), ChaqaqError> {
    let mut doc = repo.load(doc_id)?;
    let mut reordonnés: Vec<Block> = Vec::with_capacity(doc.blocks.len());
    for id in &order {
        if let Some(pos) = doc.blocks.iter().position(|b| b.id == *id) {
            reordonnés.push(doc.blocks.remove(pos));
        }
    }
    reordonnés.extend(doc.blocks);
    doc.blocks = reordonnés;
    repo.save(&doc)
}

/// Ajoute un bloc comme enfant direct d'un bloc existant (blocs imbriqués).
pub fn add_child_block(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    parent_id: Uuid,
    content: BlockContent,
) -> Result<Block, ChaqaqError> {
    let mut doc = repo.load(doc_id)?;
    let parent =
        find_block_mut(&mut doc.blocks, parent_id).ok_or(ChaqaqError::NotFound(parent_id))?;
    let enfant = Block::new(content);
    parent.children.push(enfant.clone());
    repo.save(&doc)?;
    Ok(enfant)
}

// ── Recherche ─────────────────────────────────────────────────────────────────

/// Recherche insensible à la casse dans les titles de documents.
pub fn search_documents(
    repo: &dyn DocumentRepository,
    query: &str,
) -> Result<Vec<DocumentMeta>, ChaqaqError> {
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

fn find_block_mut(blocs: &mut Vec<Block>, id: Uuid) -> Option<&mut Block> {
    // première passe : cherche au niveau courant
    if let Some(pos) = blocs.iter().position(|b| b.id == id) {
        return Some(&mut blocs[pos]);
    }
    // deuxième passe : récursion dans les enfants
    for bloc in blocs.iter_mut() {
        if let Some(found) = find_block_mut(&mut bloc.children, id) {
            return Some(found);
        }
    }
    None
}

fn delete_from_tree(blocs: &mut Vec<Block>, id: Uuid) -> bool {
    let avant = blocs.len();
    blocs.retain(|b| b.id != id);
    if blocs.len() < avant {
        return true;
    }
    blocs
        .iter_mut()
        .any(|b| delete_from_tree(&mut b.children, id))
}

fn extract_block(blocs: &mut Vec<Block>, id: Uuid) -> Option<Block> {
    if let Some(pos) = blocs.iter().position(|b| b.id == id) {
        return Some(blocs.remove(pos));
    }
    for bloc in blocs.iter_mut() {
        if let Some(found) = extract_block(&mut bloc.children, id) {
            return Some(found);
        }
    }
    None
}

fn blocks_contain(blocs: &[Block], query: &str) -> bool {
    blocs.iter().any(|b| block_contains(b, query))
}

fn block_contains(bloc: &Block, query: &str) -> bool {
    let texte = match &bloc.content {
        BlockContent::Text(inlines)
        | BlockContent::Heading { text: inlines, .. }
        | BlockContent::Quote { text: inlines, .. }
        | BlockContent::Todo { text: inlines, .. } => inlines
            .iter()
            .any(|i| i.content.to_lowercase().contains(query)),
        _ => false,
    };
    texte || blocks_contain(&bloc.children, query)
}

// ── Blocs imbriqués — réordonnement et déplacement ───────────────────────────

/// Réordonne les blocs enfants d'un bloc parent selon la liste d'UUIDs fournie.
/// Les enfants absents de la liste sont conservés et placés à la fin.
pub fn reorder_child_blocks(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    parent_id: Uuid,
    order: Vec<Uuid>,
) -> Result<(), ChaqaqError> {
    let mut doc = repo.load(doc_id)?;
    let parent =
        find_block_mut(&mut doc.blocks, parent_id).ok_or(ChaqaqError::NotFound(parent_id))?;
    let mut reordonnes: Vec<Block> = Vec::with_capacity(parent.children.len());
    for id in &order {
        if let Some(pos) = parent.children.iter().position(|b| b.id == *id) {
            reordonnes.push(parent.children.remove(pos));
        }
    }
    reordonnes.extend(parent.children.drain(..));
    parent.children = reordonnes;
    repo.save(&doc)
}

/// Déplace un bloc vers un nouveau parent (None = racine du document).
/// Retourne InvalidOperation si block_id == new_parent_id.
pub fn move_block(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    block_id: Uuid,
    new_parent_id: Option<Uuid>,
) -> Result<(), ChaqaqError> {
    if new_parent_id == Some(block_id) {
        return Err(ChaqaqError::InvalidOperation(
            "impossible de déplacer un bloc dans lui-même".to_string(),
        ));
    }
    let mut doc = repo.load(doc_id)?;
    let bloc = extract_block(&mut doc.blocks, block_id).ok_or(ChaqaqError::NotFound(block_id))?;
    match new_parent_id {
        None => doc.blocks.push(bloc),
        Some(parent_id) => {
            let parent = find_block_mut(&mut doc.blocks, parent_id)
                .ok_or(ChaqaqError::NotFound(parent_id))?;
            parent.children.push(bloc);
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
) -> Result<Vec<DocumentMeta>, ChaqaqError> {
    let q = query.to_lowercase();
    let metas = repo.list()?;
    let mut resultats = Vec::new();
    for meta in metas {
        let doc = repo.load(meta.id)?;
        if blocks_contain(&doc.blocks, &q) {
            resultats.push(meta);
        }
    }
    Ok(resultats)
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
        fn nouveau() -> Self {
            Self {
                docs: RefCell::new(HashMap::new()),
            }
        }
    }

    impl DocumentRepository for MockRepo {
        fn save(&self, doc: &Document) -> Result<(), ChaqaqError> {
            self.docs.borrow_mut().insert(doc.id, doc.clone());
            Ok(())
        }
        fn load(&self, id: Uuid) -> Result<Document, ChaqaqError> {
            self.docs
                .borrow()
                .get(&id)
                .cloned()
                .ok_or(ChaqaqError::NotFound(id))
        }
        fn list(&self) -> Result<Vec<DocumentMeta>, ChaqaqError> {
            Ok(self
                .docs
                .borrow()
                .values()
                .map(DocumentMeta::from)
                .collect())
        }
        fn delete(&self, id: Uuid) -> Result<(), ChaqaqError> {
            self.docs
                .borrow_mut()
                .remove(&id)
                .map(|_| ())
                .ok_or(ChaqaqError::NotFound(id))
        }
    }

    fn inline(s: &str) -> Vec<InlineText> {
        vec![InlineText {
            content: s.to_string(),
            styles: vec![],
        }]
    }

    fn doc_avec_blocs(title: &str, blocs: Vec<Block>) -> Document {
        let mut doc = Document::new(inline(title));
        doc.blocks = blocs;
        doc
    }

    fn bloc_texte(s: &str) -> Block {
        Block::new(BlockContent::Text(inline(s)))
    }

    #[test]
    fn test_reorder_child_blocks() {
        let repo = MockRepo::nouveau();
        let mut doc = Document::new(inline("Test"));
        let parent = Block::new(BlockContent::Text(inline("parent")));
        let parent_id = parent.id;
        doc.blocks.push(parent);
        repo.save(&doc).unwrap();

        let enfant_a =
            add_child_block(&repo, doc.id, parent_id, BlockContent::Text(inline("A"))).unwrap();
        let enfant_b =
            add_child_block(&repo, doc.id, parent_id, BlockContent::Text(inline("B"))).unwrap();
        let enfant_c =
            add_child_block(&repo, doc.id, parent_id, BlockContent::Text(inline("C"))).unwrap();

        reorder_child_blocks(
            &repo,
            doc.id,
            parent_id,
            vec![enfant_c.id, enfant_a.id, enfant_b.id],
        )
        .unwrap();

        let doc = repo.load(doc.id).unwrap();
        let enfants = &doc.blocks[0].children;
        assert_eq!(enfants[0].id, enfant_c.id);
        assert_eq!(enfants[1].id, enfant_a.id);
        assert_eq!(enfants[2].id, enfant_b.id);
    }

    #[test]
    fn test_move_block_racine_vers_enfant() {
        let repo = MockRepo::nouveau();
        let mut doc = Document::new(inline("Test"));
        let parent = bloc_texte("parent");
        let enfant = bloc_texte("à déplacer");
        let parent_id = parent.id;
        let enfant_id = enfant.id;
        doc.blocks.push(parent);
        doc.blocks.push(enfant);
        repo.save(&doc).unwrap();

        move_block(&repo, doc.id, enfant_id, Some(parent_id)).unwrap();

        let doc = repo.load(doc.id).unwrap();
        assert_eq!(doc.blocks.len(), 1);
        assert_eq!(doc.blocks[0].children.len(), 1);
        assert_eq!(doc.blocks[0].children[0].id, enfant_id);
    }

    #[test]
    fn test_move_block_enfant_vers_racine() {
        let repo = MockRepo::nouveau();
        let mut doc = Document::new(inline("Test"));
        let mut parent = bloc_texte("parent");
        let enfant = bloc_texte("enfant");
        let enfant_id = enfant.id;
        parent.children.push(enfant);
        doc.blocks.push(parent);
        repo.save(&doc).unwrap();

        move_block(&repo, doc.id, enfant_id, None).unwrap();

        let doc = repo.load(doc.id).unwrap();
        assert_eq!(doc.blocks.len(), 2);
        assert!(doc.blocks[0].children.is_empty());
        assert_eq!(doc.blocks[1].id, enfant_id);
    }

    #[test]
    fn test_move_block_dans_lui_meme_erreur() {
        let repo = MockRepo::nouveau();
        let mut doc = Document::new(inline("Test"));
        let bloc = bloc_texte("bloc");
        let block_id = bloc.id;
        doc.blocks.push(bloc);
        repo.save(&doc).unwrap();

        let res = move_block(&repo, doc.id, block_id, Some(block_id));
        assert!(matches!(res, Err(ChaqaqError::InvalidOperation(_))));
    }

    #[test]
    fn test_search_in_blocks_trouve() {
        let repo = MockRepo::nouveau();
        let doc = doc_avec_blocs("Doc", vec![bloc_texte("Rust est génial")]);
        repo.save(&doc).unwrap();

        let resultats = search_in_blocks(&repo, "rust").unwrap();
        assert_eq!(resultats.len(), 1);
        assert_eq!(resultats[0].id, doc.id);
    }

    #[test]
    fn test_search_in_blocks_pas_de_resultat() {
        let repo = MockRepo::nouveau();
        let doc = doc_avec_blocs("Doc", vec![bloc_texte("Bonjour monde")]);
        repo.save(&doc).unwrap();

        let resultats = search_in_blocks(&repo, "flutter").unwrap();
        assert!(resultats.is_empty());
    }

    #[test]
    fn test_search_in_blocks_enfants() {
        let repo = MockRepo::nouveau();
        let mut parent = bloc_texte("parent");
        parent
            .children
            .push(bloc_texte("texte caché en profondeur"));
        let doc = doc_avec_blocs("Doc", vec![parent]);
        repo.save(&doc).unwrap();

        let resultats = search_in_blocks(&repo, "profondeur").unwrap();
        assert_eq!(resultats.len(), 1);
    }
}
