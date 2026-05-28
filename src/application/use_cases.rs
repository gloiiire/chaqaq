use uuid::Uuid;
use crate::application::error::ChaqaqError;
use crate::application::repository::DocumentRepository;
use crate::domain::document::{Block, BlockContent, Document, DocumentMeta, InlineText};
use crate::domain::editor::EditorState;
use crate::domain::parser::parse_inline;

pub fn creer_document(
    repo: &dyn DocumentRepository,
    titre: &str,
) -> Result<Document, ChaqaqError> {
    let doc = Document::new(parse_inline(titre));
    repo.save(&doc)?;
    Ok(doc)
}

pub fn obtenir_document(
    repo: &dyn DocumentRepository,
    id: Uuid,
) -> Result<Document, ChaqaqError> {
    repo.load(id)
}

pub fn lister_documents(
    repo: &dyn DocumentRepository,
) -> Result<Vec<DocumentMeta>, ChaqaqError> {
    repo.list()
}

pub fn supprimer_document(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
) -> Result<(), ChaqaqError> {
    repo.delete(doc_id)
}

pub fn ajouter_bloc(
    repo: &dyn DocumentRepository,
    id: Uuid,
    contenu: BlockContent,
) -> Result<Document, ChaqaqError> {
    let mut doc = repo.load(id)?;
    doc.add_block(contenu);
    repo.save(&doc)?;
    Ok(doc)
}

// ── Métadonnées du document ───────────────────────────────────────────────────

pub fn modifier_titre_document(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    nouveau_titre: &str,
) -> Result<(), ChaqaqError> {
    let mut doc = repo.load(doc_id)?;
    doc.title = parse_inline(nouveau_titre);
    repo.save(&doc)
}

pub fn modifier_couverture_document(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    couverture: Option<String>,
) -> Result<(), ChaqaqError> {
    let mut doc = repo.load(doc_id)?;
    doc.cover = couverture;
    repo.save(&doc)
}

// ── Bridge EditorState → Block ────────────────────────────────────────────────

/// Applique le contenu de l'éditeur sur un bloc textuel et persiste le document.
/// Retourne OperationInvalide si le bloc ne porte pas de texte (Divider, Database…).
pub fn sauvegarder_bloc_edite(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    block_id: Uuid,
    etat: &EditorState,
) -> Result<(), ChaqaqError> {
    let mut doc = repo.load(doc_id)?;
    let inlines: Vec<InlineText> = Vec::from(&etat.texte);
    let bloc = trouver_bloc_mut(&mut doc.blocks, block_id)
        .ok_or(ChaqaqError::NonTrouve(block_id))?;

    bloc.content = match &bloc.content {
        BlockContent::Text(_) =>
            BlockContent::Text(inlines),
        BlockContent::Heading { level, .. } =>
            BlockContent::Heading { text: inlines, level: *level },
        BlockContent::Quote { icon, .. } =>
            BlockContent::Quote { icon: icon.clone(), text: inlines },
        BlockContent::Todo { done, .. } =>
            BlockContent::Todo { text: inlines, done: *done },
        _ => return Err(ChaqaqError::OperationInvalide(
            format!("le bloc {block_id} ne contient pas de texte éditable")
        )),
    };
    repo.save(&doc)
}

// ── Gestion des blocs ─────────────────────────────────────────────────────────

/// Remplace le contenu d'un bloc existant (toggle todo, changement de type…).
pub fn modifier_bloc(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    block_id: Uuid,
    nouveau_contenu: BlockContent,
) -> Result<(), ChaqaqError> {
    let mut doc = repo.load(doc_id)?;
    let bloc = trouver_bloc_mut(&mut doc.blocks, block_id)
        .ok_or(ChaqaqError::NonTrouve(block_id))?;
    bloc.content = nouveau_contenu;
    repo.save(&doc)
}

/// Supprime un bloc (et ses enfants) dans l'arbre du document.
pub fn supprimer_bloc(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    block_id: Uuid,
) -> Result<(), ChaqaqError> {
    let mut doc = repo.load(doc_id)?;
    if !supprimer_de_tree(&mut doc.blocks, block_id) {
        return Err(ChaqaqError::NonTrouve(block_id));
    }
    repo.save(&doc)
}

/// Réordonne les blocs racine selon la liste d'UUIDs fournie.
/// Les blocs absents de la liste sont conservés et placés à la fin.
pub fn reordonner_blocs(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    ordre: Vec<Uuid>,
) -> Result<(), ChaqaqError> {
    let mut doc = repo.load(doc_id)?;
    let mut reordonnés: Vec<Block> = Vec::with_capacity(doc.blocks.len());
    for id in &ordre {
        if let Some(pos) = doc.blocks.iter().position(|b| b.id == *id) {
            reordonnés.push(doc.blocks.remove(pos));
        }
    }
    reordonnés.extend(doc.blocks);
    doc.blocks = reordonnés;
    repo.save(&doc)
}

/// Ajoute un bloc comme enfant direct d'un bloc existant (blocs imbriqués).
pub fn ajouter_bloc_enfant(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    parent_id: Uuid,
    contenu: BlockContent,
) -> Result<Block, ChaqaqError> {
    let mut doc = repo.load(doc_id)?;
    let parent = trouver_bloc_mut(&mut doc.blocks, parent_id)
        .ok_or(ChaqaqError::NonTrouve(parent_id))?;
    let enfant = Block::new(contenu);
    parent.children.push(enfant.clone());
    repo.save(&doc)?;
    Ok(enfant)
}

// ── Recherche ─────────────────────────────────────────────────────────────────

/// Recherche insensible à la casse dans les titres de documents.
pub fn rechercher_documents(
    repo: &dyn DocumentRepository,
    query: &str,
) -> Result<Vec<DocumentMeta>, ChaqaqError> {
    let q = query.to_lowercase();
    Ok(repo.list()?.into_iter()
        .filter(|m| m.title.iter().any(|t| t.content.to_lowercase().contains(&q)))
        .collect())
}

// ── Helpers internes ──────────────────────────────────────────────────────────

fn trouver_bloc_mut(blocs: &mut Vec<Block>, id: Uuid) -> Option<&mut Block> {
    // première passe : cherche au niveau courant
    if let Some(pos) = blocs.iter().position(|b| b.id == id) {
        return Some(&mut blocs[pos]);
    }
    // deuxième passe : récursion dans les enfants
    for bloc in blocs.iter_mut() {
        if let Some(found) = trouver_bloc_mut(&mut bloc.children, id) {
            return Some(found);
        }
    }
    None
}

fn supprimer_de_tree(blocs: &mut Vec<Block>, id: Uuid) -> bool {
    let avant = blocs.len();
    blocs.retain(|b| b.id != id);
    if blocs.len() < avant {
        return true;
    }
    blocs.iter_mut().any(|b| supprimer_de_tree(&mut b.children, id))
}

fn extraire_bloc(blocs: &mut Vec<Block>, id: Uuid) -> Option<Block> {
    if let Some(pos) = blocs.iter().position(|b| b.id == id) {
        return Some(blocs.remove(pos));
    }
    for bloc in blocs.iter_mut() {
        if let Some(found) = extraire_bloc(&mut bloc.children, id) {
            return Some(found);
        }
    }
    None
}

fn blocs_contiennent(blocs: &[Block], query: &str) -> bool {
    blocs.iter().any(|b| bloc_contient(b, query))
}

fn bloc_contient(bloc: &Block, query: &str) -> bool {
    let texte = match &bloc.content {
        BlockContent::Text(inlines)
        | BlockContent::Heading { text: inlines, .. }
        | BlockContent::Quote { text: inlines, .. }
        | BlockContent::Todo { text: inlines, .. } => {
            inlines.iter().any(|i| i.content.to_lowercase().contains(query))
        }
        _ => false,
    };
    texte || blocs_contiennent(&bloc.children, query)
}

// ── Blocs imbriqués — réordonnement et déplacement ───────────────────────────

/// Réordonne les blocs enfants d'un bloc parent selon la liste d'UUIDs fournie.
/// Les enfants absents de la liste sont conservés et placés à la fin.
pub fn reordonner_blocs_enfants(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    parent_id: Uuid,
    ordre: Vec<Uuid>,
) -> Result<(), ChaqaqError> {
    let mut doc = repo.load(doc_id)?;
    let parent = trouver_bloc_mut(&mut doc.blocks, parent_id)
        .ok_or(ChaqaqError::NonTrouve(parent_id))?;
    let mut reordonnes: Vec<Block> = Vec::with_capacity(parent.children.len());
    for id in &ordre {
        if let Some(pos) = parent.children.iter().position(|b| b.id == *id) {
            reordonnes.push(parent.children.remove(pos));
        }
    }
    reordonnes.extend(parent.children.drain(..));
    parent.children = reordonnes;
    repo.save(&doc)
}

/// Déplace un bloc vers un nouveau parent (None = racine du document).
/// Retourne OperationInvalide si block_id == nouveau_parent_id.
pub fn deplacer_bloc(
    repo: &dyn DocumentRepository,
    doc_id: Uuid,
    block_id: Uuid,
    nouveau_parent_id: Option<Uuid>,
) -> Result<(), ChaqaqError> {
    if nouveau_parent_id == Some(block_id) {
        return Err(ChaqaqError::OperationInvalide(
            "impossible de déplacer un bloc dans lui-même".to_string(),
        ));
    }
    let mut doc = repo.load(doc_id)?;
    let bloc = extraire_bloc(&mut doc.blocks, block_id)
        .ok_or(ChaqaqError::NonTrouve(block_id))?;
    match nouveau_parent_id {
        None => doc.blocks.push(bloc),
        Some(parent_id) => {
            let parent = trouver_bloc_mut(&mut doc.blocks, parent_id)
                .ok_or(ChaqaqError::NonTrouve(parent_id))?;
            parent.children.push(bloc);
        }
    }
    repo.save(&doc)
}

// ── Recherche plein texte ─────────────────────────────────────────────────────

/// Recherche insensible à la casse dans le contenu textuel des blocs de tous les documents.
/// Retourne les métadonnées des documents qui contiennent au moins un bloc correspondant.
pub fn rechercher_dans_blocs(
    repo: &dyn DocumentRepository,
    query: &str,
) -> Result<Vec<DocumentMeta>, ChaqaqError> {
    let q = query.to_lowercase();
    let metas = repo.list()?;
    let mut resultats = Vec::new();
    for meta in metas {
        let doc = repo.load(meta.id)?;
        if blocs_contiennent(&doc.blocks, &q) {
            resultats.push(meta);
        }
    }
    Ok(resultats)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::cell::RefCell;
    use crate::domain::document::InlineText;

    struct MockRepo {
        docs: RefCell<HashMap<Uuid, Document>>,
    }

    impl MockRepo {
        fn nouveau() -> Self {
            Self { docs: RefCell::new(HashMap::new()) }
        }
    }

    impl DocumentRepository for MockRepo {
        fn save(&self, doc: &Document) -> Result<(), ChaqaqError> {
            self.docs.borrow_mut().insert(doc.id, doc.clone());
            Ok(())
        }
        fn load(&self, id: Uuid) -> Result<Document, ChaqaqError> {
            self.docs.borrow().get(&id).cloned()
                .ok_or(ChaqaqError::NonTrouve(id))
        }
        fn list(&self) -> Result<Vec<DocumentMeta>, ChaqaqError> {
            Ok(self.docs.borrow().values().map(DocumentMeta::from).collect())
        }
        fn delete(&self, id: Uuid) -> Result<(), ChaqaqError> {
            self.docs.borrow_mut().remove(&id)
                .map(|_| ())
                .ok_or(ChaqaqError::NonTrouve(id))
        }
    }

    fn inline(s: &str) -> Vec<InlineText> {
        vec![InlineText { content: s.to_string(), styles: vec![] }]
    }

    fn doc_avec_blocs(titre: &str, blocs: Vec<Block>) -> Document {
        let mut doc = Document::new(inline(titre));
        doc.blocks = blocs;
        doc
    }

    fn bloc_texte(s: &str) -> Block {
        Block::new(BlockContent::Text(inline(s)))
    }

    #[test]
    fn test_reordonner_blocs_enfants() {
        let repo = MockRepo::nouveau();
        let mut doc = Document::new(inline("Test"));
        let parent = Block::new(BlockContent::Text(inline("parent")));
        let parent_id = parent.id;
        doc.blocks.push(parent);
        repo.save(&doc).unwrap();

        let enfant_a = ajouter_bloc_enfant(&repo, doc.id, parent_id, BlockContent::Text(inline("A"))).unwrap();
        let enfant_b = ajouter_bloc_enfant(&repo, doc.id, parent_id, BlockContent::Text(inline("B"))).unwrap();
        let enfant_c = ajouter_bloc_enfant(&repo, doc.id, parent_id, BlockContent::Text(inline("C"))).unwrap();

        reordonner_blocs_enfants(&repo, doc.id, parent_id, vec![enfant_c.id, enfant_a.id, enfant_b.id]).unwrap();

        let doc = repo.load(doc.id).unwrap();
        let enfants = &doc.blocks[0].children;
        assert_eq!(enfants[0].id, enfant_c.id);
        assert_eq!(enfants[1].id, enfant_a.id);
        assert_eq!(enfants[2].id, enfant_b.id);
    }

    #[test]
    fn test_deplacer_bloc_racine_vers_enfant() {
        let repo = MockRepo::nouveau();
        let mut doc = Document::new(inline("Test"));
        let parent = bloc_texte("parent");
        let enfant = bloc_texte("à déplacer");
        let parent_id = parent.id;
        let enfant_id = enfant.id;
        doc.blocks.push(parent);
        doc.blocks.push(enfant);
        repo.save(&doc).unwrap();

        deplacer_bloc(&repo, doc.id, enfant_id, Some(parent_id)).unwrap();

        let doc = repo.load(doc.id).unwrap();
        assert_eq!(doc.blocks.len(), 1);
        assert_eq!(doc.blocks[0].children.len(), 1);
        assert_eq!(doc.blocks[0].children[0].id, enfant_id);
    }

    #[test]
    fn test_deplacer_bloc_enfant_vers_racine() {
        let repo = MockRepo::nouveau();
        let mut doc = Document::new(inline("Test"));
        let mut parent = bloc_texte("parent");
        let enfant = bloc_texte("enfant");
        let enfant_id = enfant.id;
        parent.children.push(enfant);
        doc.blocks.push(parent);
        repo.save(&doc).unwrap();

        deplacer_bloc(&repo, doc.id, enfant_id, None).unwrap();

        let doc = repo.load(doc.id).unwrap();
        assert_eq!(doc.blocks.len(), 2);
        assert!(doc.blocks[0].children.is_empty());
        assert_eq!(doc.blocks[1].id, enfant_id);
    }

    #[test]
    fn test_deplacer_bloc_dans_lui_meme_erreur() {
        let repo = MockRepo::nouveau();
        let mut doc = Document::new(inline("Test"));
        let bloc = bloc_texte("bloc");
        let bloc_id = bloc.id;
        doc.blocks.push(bloc);
        repo.save(&doc).unwrap();

        let res = deplacer_bloc(&repo, doc.id, bloc_id, Some(bloc_id));
        assert!(matches!(res, Err(ChaqaqError::OperationInvalide(_))));
    }

    #[test]
    fn test_rechercher_dans_blocs_trouve() {
        let repo = MockRepo::nouveau();
        let doc = doc_avec_blocs("Doc", vec![bloc_texte("Rust est génial")]);
        repo.save(&doc).unwrap();

        let resultats = rechercher_dans_blocs(&repo, "rust").unwrap();
        assert_eq!(resultats.len(), 1);
        assert_eq!(resultats[0].id, doc.id);
    }

    #[test]
    fn test_rechercher_dans_blocs_pas_de_resultat() {
        let repo = MockRepo::nouveau();
        let doc = doc_avec_blocs("Doc", vec![bloc_texte("Bonjour monde")]);
        repo.save(&doc).unwrap();

        let resultats = rechercher_dans_blocs(&repo, "flutter").unwrap();
        assert!(resultats.is_empty());
    }

    #[test]
    fn test_rechercher_dans_blocs_enfants() {
        let repo = MockRepo::nouveau();
        let mut parent = bloc_texte("parent");
        parent.children.push(bloc_texte("texte caché en profondeur"));
        let doc = doc_avec_blocs("Doc", vec![parent]);
        repo.save(&doc).unwrap();

        let resultats = rechercher_dans_blocs(&repo, "profondeur").unwrap();
        assert_eq!(resultats.len(), 1);
    }
}
