use crate::application::error::PinkhaError;
use crate::domain::document::{Document, DocumentMeta};
use uuid::Uuid;

/// Persistence contract for documents.
///
/// Any storage backend (SQLite, JSON, in-memory mock) must implement this trait.
/// Use cases depend exclusively on this abstraction — never on a concrete store.
pub trait DocumentRepository: Send + Sync {
    /// Persists a document, creating or replacing it as needed.
    fn save(&self, doc: &Document) -> Result<(), PinkhaError>;

    /// Loads the full document including all blocks.
    fn load(&self, id: Uuid) -> Result<Document, PinkhaError>;

    /// Returns lightweight metadata for all documents (no blocks loaded).
    fn list(&self) -> Result<Vec<DocumentMeta>, PinkhaError>;

    /// Soft-deletes (or permanently removes) a document by ID.
    fn delete(&self, id: Uuid) -> Result<(), PinkhaError>;

    /// Moves a document into a folder (or to root if `folder_id` is None).
    fn move_to_folder(&self, doc_id: Uuid, folder_id: Option<Uuid>) -> Result<(), PinkhaError>;

    /// Lists metadata for documents in a specific folder (None = root-level only).
    fn list_by_folder(&self, folder_id: Option<Uuid>) -> Result<Vec<DocumentMeta>, PinkhaError>;

    /// Returns metadata for documents that have been soft-deleted (in the trash).
    /// Sorted newest-deleted first. Empty default impl so existing in-memory
    /// mocks compile without change; production stores override.
    fn list_deleted(&self) -> Result<Vec<DocumentMeta>, PinkhaError> {
        Ok(vec![])
    }

    /// Restores a soft-deleted document by clearing its `deleted_at`. Returns
    /// `NotFound` when the id doesn't match a soft-deleted document.
    fn restore(&self, _id: Uuid) -> Result<(), PinkhaError> {
        Err(PinkhaError::InvalidOperation(
            "restore not supported by this repository".into(),
        ))
    }

    /// Permanently removes a soft-deleted document — hard delete after this.
    /// Implementations should refuse when the document is still live
    /// (`deleted_at IS NULL`) to prevent accidental data loss.
    fn purge(&self, _id: Uuid) -> Result<(), PinkhaError> {
        Err(PinkhaError::InvalidOperation(
            "purge not supported by this repository".into(),
        ))
    }
}
