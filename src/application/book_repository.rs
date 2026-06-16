use crate::application::error::PinkhaError;
use crate::domain::book::{Book, BookMeta};
use uuid::Uuid;

/// Persistence contract for books.
///
/// Any storage backend (SQLite, JSON, in-memory mock) must implement this trait.
/// Book use cases depend exclusively on this abstraction — never on a concrete store.
pub trait BookRepository: Send + Sync {
    /// Persists a book, creating or replacing it as needed.
    fn save(&self, db: &Book) -> Result<(), PinkhaError>;

    /// Loads a full book including all properties, entries, and views.
    fn load(&self, id: Uuid) -> Result<Book, PinkhaError>;

    /// Returns lightweight metadata for all books (no entries loaded).
    fn list_meta(&self) -> Result<Vec<BookMeta>, PinkhaError>;

    /// Soft-deletes (or permanently removes) a book by ID.
    fn delete(&self, id: Uuid) -> Result<(), PinkhaError>;

    /// Returns metadata for soft-deleted books (in the trash), newest first.
    fn list_deleted(&self) -> Result<Vec<BookMeta>, PinkhaError> {
        Ok(vec![])
    }

    /// Restores a soft-deleted book by clearing its `deleted_at`. Returns
    /// `NotFound` when the id doesn't match a soft-deleted book.
    fn restore(&self, _id: Uuid) -> Result<(), PinkhaError> {
        Err(PinkhaError::InvalidOperation(
            "restore not supported by this repository".into(),
        ))
    }

    /// Permanently removes a soft-deleted book. Implementations should
    /// refuse when the book is still live.
    fn purge(&self, _id: Uuid) -> Result<(), PinkhaError> {
        Err(PinkhaError::InvalidOperation(
            "purge not supported by this repository".into(),
        ))
    }
}
