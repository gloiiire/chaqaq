use crate::application::error::PinkhaError;
use crate::domain::database::{Database, DatabaseMeta};
use uuid::Uuid;

/// Persistence contract for databases.
///
/// Any storage backend (SQLite, JSON, in-memory mock) must implement this trait.
/// Database use cases depend exclusively on this abstraction — never on a concrete store.
pub trait DatabaseRepository: Send + Sync {
    /// Persists a database, creating or replacing it as needed.
    fn save(&self, db: &Database) -> Result<(), PinkhaError>;

    /// Loads a full database including all properties, entries, and views.
    fn load(&self, id: Uuid) -> Result<Database, PinkhaError>;

    /// Returns lightweight metadata for all databases (no entries loaded).
    fn list_meta(&self) -> Result<Vec<DatabaseMeta>, PinkhaError>;

    /// Soft-deletes (or permanently removes) a database by ID.
    fn delete(&self, id: Uuid) -> Result<(), PinkhaError>;
}
