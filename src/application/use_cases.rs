use uuid::Uuid;
use crate::application::repository::DocumentRepository;
use crate::domain::document::{BlockContent, Document, DocumentMeta};
use crate::domain::parser::parse_inline;

pub fn creer_document(
    repo: &dyn DocumentRepository,
    titre: &str,
) -> Result<Document, Box<dyn std::error::Error>> {
    let doc = Document::new(parse_inline(titre));
    repo.save(&doc)?;
    Ok(doc)
}

pub fn obtenir_document(
    repo: &dyn DocumentRepository,
    id: Uuid,
) -> Result<Document, Box<dyn std::error::Error>> {
    repo.load(id)
}

pub fn lister_documents(
    repo: &dyn DocumentRepository,
) -> Result<Vec<DocumentMeta>, Box<dyn std::error::Error>> {
    repo.list()
}

pub fn ajouter_bloc(
    repo: &dyn DocumentRepository,
    id: Uuid,
    contenu: BlockContent,
) -> Result<Document, Box<dyn std::error::Error>> {
    let mut doc = repo.load(id)?;
    doc.add_block(contenu);
    repo.save(&doc)?;
    Ok(doc)
}
