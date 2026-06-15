use crate::application::error::PinkhaError;
use crate::domain::leaf::{Leaf, LeafMeta};
use uuid::Uuid;

/// Persistence contract for leaves.
///
/// Any storage backend (SQLite, JSON, in-memory mock) must implement this trait.
/// Use cases depend exclusively on this abstraction — never on a concrete store.
pub trait LeafRepository: Send + Sync {
    /// Persists a leaf, creating or replacing it as needed.
    fn save(&self, doc: &Leaf) -> Result<(), PinkhaError>;

    /// Loads the full leaf including all blocks.
    fn load(&self, id: Uuid) -> Result<Leaf, PinkhaError>;

    /// Returns lightweight metadata for all leaves (no blocks loaded).
    fn list(&self) -> Result<Vec<LeafMeta>, PinkhaError>;

    /// Soft-deletes (or permanently removes) a leaf by ID.
    fn delete(&self, id: Uuid) -> Result<(), PinkhaError>;

    /// Moves a leaf into a shelf (or to root if `shelf_id` is None).
    fn move_to_shelf(&self, leaf_id: Uuid, shelf_id: Option<Uuid>) -> Result<(), PinkhaError>;

    /// Lists metadata for leaves in a specific shelf (None = root-level only).
    fn list_by_shelf(&self, shelf_id: Option<Uuid>) -> Result<Vec<LeafMeta>, PinkhaError>;

    /// Returns metadata for leaves that have been soft-deleted (in the trash).
    /// Sorted newest-deleted first. Empty default impl so existing in-memory
    /// mocks compile without change; production stores override.
    fn list_deleted(&self) -> Result<Vec<LeafMeta>, PinkhaError> {
        Ok(vec![])
    }

    /// Restores a soft-deleted leaf by clearing its `deleted_at`. Returns
    /// `NotFound` when the id doesn't match a soft-deleted leaf.
    fn restore(&self, _id: Uuid) -> Result<(), PinkhaError> {
        Err(PinkhaError::InvalidOperation(
            "restore not supported by this repository".into(),
        ))
    }

    /// Permanently removes a soft-deleted leaf — hard delete after this.
    /// Implementations should refuse when the leaf is still live
    /// (`deleted_at IS NULL`) to prevent accidental data loss.
    fn purge(&self, _id: Uuid) -> Result<(), PinkhaError> {
        Err(PinkhaError::InvalidOperation(
            "purge not supported by this repository".into(),
        ))
    }
}
