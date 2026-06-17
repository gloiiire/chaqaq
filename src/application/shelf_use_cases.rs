use crate::application::error::PinkhaError;
use crate::application::unit_of_work::UnitOfWork;
use crate::domain::shelf::{Shelf, ShelfMeta};
use uuid::Uuid;

pub fn create_shelf(
    uow: &dyn UnitOfWork,
    name: &str,
    parent_id: Option<Uuid>,
) -> Result<Shelf, PinkhaError> {
    uow.shelves().create(name, parent_id)
}

pub fn get_shelf(uow: &dyn UnitOfWork, id: Uuid) -> Result<Shelf, PinkhaError> {
    uow.shelves().get(id)
}

pub fn list_shelves(uow: &dyn UnitOfWork) -> Result<Vec<ShelfMeta>, PinkhaError> {
    uow.shelves().list()
}

/// Returns the direct children of `parent_id` (`None` = root-level shelves).
pub fn list_child_shelves(
    uow: &dyn UnitOfWork,
    parent_id: Option<Uuid>,
) -> Result<Vec<ShelfMeta>, PinkhaError> {
    Ok(uow
        .shelves()
        .list()?
        .into_iter()
        .filter(|f| f.parent_id == parent_id)
        .collect())
}

pub fn rename_shelf(uow: &dyn UnitOfWork, id: Uuid, new_name: &str) -> Result<(), PinkhaError> {
    uow.shelves().rename(id, new_name)
}

pub fn delete_shelf(uow: &dyn UnitOfWork, id: Uuid) -> Result<(), PinkhaError> {
    uow.shelves().delete(id)
}

pub fn move_shelf(
    uow: &dyn UnitOfWork,
    id: Uuid,
    new_parent_id: Option<Uuid>,
) -> Result<(), PinkhaError> {
    uow.shelves().move_shelf(id, new_parent_id)
}

/// Bulk-rewrites the manual order. First id gets index 0, etc.
pub fn set_shelves_manual_order(
    uow: &dyn UnitOfWork,
    ordered_ids: &[Uuid],
) -> Result<(), PinkhaError> {
    uow.shelves().set_manual_order(ordered_ids)
}

/// Sets or clears the shelf's emoji icon.
pub fn update_shelf_icon(
    uow: &dyn UnitOfWork,
    id: Uuid,
    icon: Option<&str>,
) -> Result<(), PinkhaError> {
    uow.shelves().update_icon(id, icon)
}

/// Lists soft-deleted shelves (newest-deleted first).
pub fn list_deleted_shelves(uow: &dyn UnitOfWork) -> Result<Vec<ShelfMeta>, PinkhaError> {
    uow.shelves().list_deleted()
}

/// Restores a soft-deleted shelf.
pub fn restore_shelf(uow: &dyn UnitOfWork, id: Uuid) -> Result<(), PinkhaError> {
    uow.shelves().restore(id)
}

/// Permanently deletes a soft-deleted shelf (hard delete).
pub fn purge_shelf(uow: &dyn UnitOfWork, id: Uuid) -> Result<(), PinkhaError> {
    uow.shelves().purge(id)
}
