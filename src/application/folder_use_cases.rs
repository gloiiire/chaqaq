use crate::application::error::PinkhaError;
use crate::application::unit_of_work::UnitOfWork;
use crate::domain::folder::{Folder, FolderMeta};
use uuid::Uuid;

pub fn create_folder(
    uow: &dyn UnitOfWork,
    name: &str,
    parent_id: Option<Uuid>,
) -> Result<Folder, PinkhaError> {
    uow.folders().create(name, parent_id)
}

pub fn get_folder(uow: &dyn UnitOfWork, id: Uuid) -> Result<Folder, PinkhaError> {
    uow.folders().get(id)
}

pub fn list_folders(uow: &dyn UnitOfWork) -> Result<Vec<FolderMeta>, PinkhaError> {
    uow.folders().list()
}

pub fn rename_folder(uow: &dyn UnitOfWork, id: Uuid, new_name: &str) -> Result<(), PinkhaError> {
    uow.folders().rename(id, new_name)
}

pub fn delete_folder(uow: &dyn UnitOfWork, id: Uuid) -> Result<(), PinkhaError> {
    uow.folders().delete(id)
}

pub fn move_folder(
    uow: &dyn UnitOfWork,
    id: Uuid,
    new_parent_id: Option<Uuid>,
) -> Result<(), PinkhaError> {
    uow.folders().move_folder(id, new_parent_id)
}

/// Sets or clears the folder's emoji icon.
pub fn update_folder_icon(
    uow: &dyn UnitOfWork,
    id: Uuid,
    icon: Option<&str>,
) -> Result<(), PinkhaError> {
    uow.folders().update_icon(id, icon)
}

/// Lists soft-deleted folders (newest-deleted first).
pub fn list_deleted_folders(uow: &dyn UnitOfWork) -> Result<Vec<FolderMeta>, PinkhaError> {
    uow.folders().list_deleted()
}

/// Restores a soft-deleted folder.
pub fn restore_folder(uow: &dyn UnitOfWork, id: Uuid) -> Result<(), PinkhaError> {
    uow.folders().restore(id)
}

/// Permanently deletes a soft-deleted folder (hard delete).
pub fn purge_folder(uow: &dyn UnitOfWork, id: Uuid) -> Result<(), PinkhaError> {
    uow.folders().purge(id)
}
