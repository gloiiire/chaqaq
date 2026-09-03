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

    /// Pins or unpins a leaf. Pinning sets `pinned_at` to the current
    /// RFC 3339 timestamp ; unpinning clears it back to `NULL`. The
    /// home view's PINNED section reads these via `list()`. Default
    /// impl errors so in-memory mocks compile until they opt in.
    /// Metadata for a single leaf, sourced from the **indexed columns**.
    ///
    /// The default implementation derives it from a full `load()`, which
    /// cannot see the column-only fields: `LeafMeta::from(&Leaf)` has no
    /// `updated_at` / `created_at` to read off the struct and leaves them
    /// empty. Stores backed by a real table should override this with a
    /// single-row projection so the result matches what `list()` returns
    /// for the same leaf — callers legitimately expect the two to agree.
    fn load_meta(&self, id: Uuid) -> Result<LeafMeta, PinkhaError> {
        Ok(LeafMeta::from(&self.load(id)?))
    }

    fn set_pinned(&self, _leaf_id: Uuid, _pinned: bool) -> Result<(), PinkhaError> {
        Err(PinkhaError::InvalidOperation(
            "set_pinned not supported by this repository".into(),
        ))
    }

    /// Bulk-rewrites the manual sort index. The first id in
    /// `ordered_ids` gets index 0, the second gets 1, and so on. Used
    /// by the drag-and-drop reorder UI in the PINNED section and the
    /// "All" section's manual sort mode.
    fn set_manual_order(&self, _ordered_ids: &[Uuid]) -> Result<(), PinkhaError> {
        Err(PinkhaError::InvalidOperation(
            "set_manual_order not supported by this repository".into(),
        ))
    }
}
