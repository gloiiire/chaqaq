use crate::application::error::PinkhaError;
use crate::domain::folder::{Folder, FolderMeta};
use uuid::Uuid;

/// Persistence contract for folders.
pub trait FolderRepository: Send + Sync {
    fn create(&self, name: &str, parent_id: Option<Uuid>) -> Result<Folder, PinkhaError>;
    fn get(&self, id: Uuid) -> Result<Folder, PinkhaError>;
    fn list(&self) -> Result<Vec<FolderMeta>, PinkhaError>;
    fn rename(&self, id: Uuid, new_name: &str) -> Result<(), PinkhaError>;
    fn delete(&self, id: Uuid) -> Result<(), PinkhaError>;
    fn move_folder(&self, id: Uuid, new_parent_id: Option<Uuid>) -> Result<(), PinkhaError>;
    /// Sets (or clears with `None`) the folder's emoji icon.
    fn update_icon(&self, id: Uuid, icon: Option<&str>) -> Result<(), PinkhaError>;

    /// Returns metadata for soft-deleted folders (in the trash), newest first.
    fn list_deleted(&self) -> Result<Vec<FolderMeta>, PinkhaError> {
        Ok(vec![])
    }

    /// Restores a soft-deleted folder by clearing its `deleted_at`. Returns
    /// `NotFound` when the id doesn't match a soft-deleted folder.
    fn restore(&self, _id: Uuid) -> Result<(), PinkhaError> {
        Err(PinkhaError::InvalidOperation(
            "restore not supported by this repository".into(),
        ))
    }

    /// Permanently removes a soft-deleted folder. Implementations should
    /// refuse when the folder is still live.
    fn purge(&self, _id: Uuid) -> Result<(), PinkhaError> {
        Err(PinkhaError::InvalidOperation(
            "purge not supported by this repository".into(),
        ))
    }
}
