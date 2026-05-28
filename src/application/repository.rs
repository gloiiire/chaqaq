use crate::domain::document::Document;
use uuid::Uuid;

pub trait DocumentRepository {
    fn save(&self, doc: &Document) -> Result<(), Box<dyn std::error::Error>>;
    fn load(&self, id: Uuid) -> Result<Document, Box<dyn std::error::Error>>;
    fn list(&self) -> Result<Vec<Document>, Box<dyn std::error::Error>>;
}
