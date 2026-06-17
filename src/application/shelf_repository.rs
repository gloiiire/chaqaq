use crate::application::error::PinkhaError;
use crate::domain::shelf::{Shelf, ShelfMeta};
use uuid::Uuid;

/// Persistence contract for shelves.
pub trait ShelfRepository: Send + Sync {
    fn create(&self, name: &str, parent_id: Option<Uuid>) -> Result<Shelf, PinkhaError>;
    fn get(&self, id: Uuid) -> Result<Shelf, PinkhaError>;
    fn list(&self) -> Result<Vec<ShelfMeta>, PinkhaError>;
    fn rename(&self, id: Uuid, new_name: &str) -> Result<(), PinkhaError>;
    fn delete(&self, id: Uuid) -> Result<(), PinkhaError>;
    fn move_shelf(&self, id: Uuid, new_parent_id: Option<Uuid>) -> Result<(), PinkhaError>;
    /// Sets (or clears with `None`) the shelf's emoji icon.
    fn update_icon(&self, id: Uuid, icon: Option<&str>) -> Result<(), PinkhaError>;

    /// Returns metadata for soft-deleted shelves (in the trash), newest first.
    fn list_deleted(&self) -> Result<Vec<ShelfMeta>, PinkhaError> {
        Ok(vec![])
    }

    /// Restores a soft-deleted shelf by clearing its `deleted_at`. Returns
    /// `NotFound` when the id doesn't match a soft-deleted shelf.
    fn restore(&self, _id: Uuid) -> Result<(), PinkhaError> {
        Err(PinkhaError::InvalidOperation(
            "restore not supported by this repository".into(),
        ))
    }

    /// Permanently removes a soft-deleted shelf. Implementations should
    /// refuse when the shelf is still live.
    fn purge(&self, _id: Uuid) -> Result<(), PinkhaError> {
        Err(PinkhaError::InvalidOperation(
            "purge not supported by this repository".into(),
        ))
    }

    /// Bulk-rewrites the manual sort index. Parallel to
    /// [`crate::application::repository::LeafRepository::set_manual_order`] —
    /// powers drag-and-drop reorder in the SHELVES sections.
    fn set_manual_order(&self, _ordered_ids: &[Uuid]) -> Result<(), PinkhaError> {
        Err(PinkhaError::InvalidOperation(
            "set_manual_order not supported by this repository".into(),
        ))
    }
}
