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
