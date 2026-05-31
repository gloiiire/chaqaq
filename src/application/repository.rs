use crate::application::error::PinkhaError;
use crate::domain::document::{Document, DocumentMeta};
use uuid::Uuid;

/// Persistence contract for documents.
///
/// Any storage backend (SQLite, JSON, in-memory mock) must implement this trait.
/// Use cases depend exclusively on this abstraction — never on a concrete store.
pub trait DocumentRepository {
    /// Persists a document, creating or replacing it as needed.
    fn save(&self, doc: &Document) -> Result<(), PinkhaError>;

    /// Loads the full document including all blocks.
    fn load(&self, id: Uuid) -> Result<Document, PinkhaError>;

    /// Returns lightweight metadata for all documents (no blocks loaded).
    fn list(&self) -> Result<Vec<DocumentMeta>, PinkhaError>;

    /// Soft-deletes (or permanently removes) a document by ID.
    fn delete(&self, id: Uuid) -> Result<(), PinkhaError>;
}
