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
}
