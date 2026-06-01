use crate::application::error::PinkhaError;
use crate::application::folder_repository::FolderRepository;
use crate::domain::folder::{Folder, FolderMeta};
use uuid::Uuid;

pub fn create_folder(
    repo: &dyn FolderRepository,
    name: &str,
    parent_id: Option<Uuid>,
) -> Result<Folder, PinkhaError> {
    repo.create(name, parent_id)
}

pub fn get_folder(repo: &dyn FolderRepository, id: Uuid) -> Result<Folder, PinkhaError> {
    repo.get(id)
}

pub fn list_folders(repo: &dyn FolderRepository) -> Result<Vec<FolderMeta>, PinkhaError> {
    repo.list()
}

pub fn rename_folder(
    repo: &dyn FolderRepository,
    id: Uuid,
    new_name: &str,
) -> Result<(), PinkhaError> {
    repo.rename(id, new_name)
}

pub fn delete_folder(repo: &dyn FolderRepository, id: Uuid) -> Result<(), PinkhaError> {
    repo.delete(id)
}

pub fn move_folder(
    repo: &dyn FolderRepository,
    id: Uuid,
    new_parent_id: Option<Uuid>,
) -> Result<(), PinkhaError> {
    repo.move_folder(id, new_parent_id)
}
