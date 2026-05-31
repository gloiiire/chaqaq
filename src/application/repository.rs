use crate::application::error::PinkhaError;
use crate::domain::document::{Document, DocumentMeta};
use uuid::Uuid;

pub trait DocumentRepository {
    fn save(&self, doc: &Document) -> Result<(), PinkhaError>;
    fn load(&self, id: Uuid) -> Result<Document, PinkhaError>;
    fn list(&self) -> Result<Vec<DocumentMeta>, PinkhaError>;
    fn delete(&self, id: Uuid) -> Result<(), PinkhaError>;
}
