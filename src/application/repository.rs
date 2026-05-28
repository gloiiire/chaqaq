use crate::application::error::ChaqaqError;
use crate::domain::document::{Document, DocumentMeta};
use uuid::Uuid;

pub trait DocumentRepository {
    fn save(&self, doc: &Document) -> Result<(), ChaqaqError>;
    fn load(&self, id: Uuid) -> Result<Document, ChaqaqError>;
    fn list(&self) -> Result<Vec<DocumentMeta>, ChaqaqError>;
    fn delete(&self, id: Uuid) -> Result<(), ChaqaqError>;
}
