//! Shelf operations and leaf/shelf placement on the [`PinkhaApi`] facade.

use crate::application::{shelf_use_cases, use_cases};

use super::types::{LeafMetaFfi, ShelfMetaFfi, leaf_meta_to_ffi, shelf_meta_to_ffi};
use super::validation::{parse_uuid, validate_string};
use super::{PinkhaApi, PinkhaError};

impl PinkhaApi {
    // ── Shelves ───────────────────────────────────────────────────────────────

    pub fn create_shelf(
        &self,
        name: String,
        parent_id: Option<String>,
    ) -> Result<ShelfMetaFfi, PinkhaError> {
        validate_string(&name, "name")?;
        let pid = parent_id.as_deref().map(parse_uuid).transpose()?;
        let shelf =
            shelf_use_cases::create_shelf(&self.uow(), &name, pid).map_err(PinkhaError::from)?;
        Ok(shelf_meta_to_ffi((&shelf).into()))
    }

    pub fn get_shelf(&self, id: String) -> Result<ShelfMetaFfi, PinkhaError> {
        let uuid = parse_uuid(&id)?;
        let shelf = shelf_use_cases::get_shelf(&self.uow(), uuid).map_err(PinkhaError::from)?;
        Ok(shelf_meta_to_ffi((&shelf).into()))
    }

    pub fn list_shelves(&self) -> Result<Vec<ShelfMetaFfi>, PinkhaError> {
        shelf_use_cases::list_shelves(&self.uow())
            .map(|v| v.into_iter().map(shelf_meta_to_ffi).collect())
            .map_err(PinkhaError::from)
    }

    pub fn rename_shelf(&self, id: String, new_name: String) -> Result<(), PinkhaError> {
        validate_string(&new_name, "new_name")?;
        let uuid = parse_uuid(&id)?;
        shelf_use_cases::rename_shelf(&self.uow(), uuid, &new_name).map_err(PinkhaError::from)
    }

    /// Sets or clears a shelf's emoji icon. Pass `None` to remove.
    pub fn update_shelf_icon(&self, id: String, icon: Option<String>) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        shelf_use_cases::update_shelf_icon(&self.uow(), uuid, icon.as_deref())
            .map_err(PinkhaError::from)
    }

    pub fn delete_shelf(&self, id: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        shelf_use_cases::delete_shelf(&self.uow(), uuid).map_err(PinkhaError::from)
    }

    /// Soft-deletes every shelf. Leaves and books that lived inside
    /// are orphaned to the root (the `delete_shelf` use case handles that).
    /// Returns the number of shelves deleted.
    pub fn delete_all_shelves(&self) -> Result<u32, PinkhaError> {
        let metas = shelf_use_cases::list_shelves(&self.uow()).map_err(PinkhaError::from)?;
        let count = metas.len() as u32;
        for meta in metas {
            shelf_use_cases::delete_shelf(&self.uow(), meta.id).map_err(PinkhaError::from)?;
        }
        Ok(count)
    }

    /// Lists soft-deleted shelves (the trash). Newest-deleted first.
    pub fn list_deleted_shelves(&self) -> Result<Vec<ShelfMetaFfi>, PinkhaError> {
        shelf_use_cases::list_deleted_shelves(&self.uow())
            .map(|v| v.into_iter().map(shelf_meta_to_ffi).collect())
            .map_err(PinkhaError::from)
    }

    /// Restores a soft-deleted shelf.
    pub fn restore_shelf(&self, id: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        shelf_use_cases::restore_shelf(&self.uow(), uuid).map_err(PinkhaError::from)
    }

    /// Permanently deletes a soft-deleted shelf (purge from trash).
    pub fn purge_shelf(&self, id: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        shelf_use_cases::purge_shelf(&self.uow(), uuid).map_err(PinkhaError::from)
    }

    pub fn move_shelf_to(
        &self,
        id: String,
        new_parent_id: Option<String>,
    ) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        let pid = new_parent_id.as_deref().map(parse_uuid).transpose()?;
        shelf_use_cases::move_shelf(&self.uow(), uuid, pid).map_err(PinkhaError::from)
    }

    pub fn move_leaf_to_shelf(
        &self,
        leaf_id: String,
        shelf_id: Option<String>,
    ) -> Result<(), PinkhaError> {
        let leaf_uuid = parse_uuid(&leaf_id)?;
        let fid = shelf_id.as_deref().map(parse_uuid).transpose()?;
        use_cases::move_leaf_to_shelf(&self.uow(), leaf_uuid, fid).map_err(PinkhaError::from)
    }

    pub fn list_leaves_in_shelf(
        &self,
        shelf_id: Option<String>,
    ) -> Result<Vec<LeafMetaFfi>, PinkhaError> {
        let fid = shelf_id.as_deref().map(parse_uuid).transpose()?;
        use_cases::list_leaves_in_shelf(&self.uow(), fid)
            .map(|v| v.into_iter().map(leaf_meta_to_ffi).collect())
            .map_err(PinkhaError::from)
    }

    /// Sets the parent leaf for page-in-page hierarchy. Pass `None`
    /// to promote the leaf back to root. Rejects cycles.
    pub fn update_leaf_parent(
        &self,
        leaf_id: String,
        new_parent_leaf_id: Option<String>,
    ) -> Result<(), PinkhaError> {
        let leaf_uuid = parse_uuid(&leaf_id)?;
        let parent = new_parent_leaf_id.as_deref().map(parse_uuid).transpose()?;
        use_cases::update_leaf_parent(&self.uow(), leaf_uuid, parent).map_err(PinkhaError::from)
    }

    /// Lists root pages (leaves with no parent). Drives the home view.
    pub fn list_root_leaves(&self) -> Result<Vec<LeafMetaFfi>, PinkhaError> {
        use_cases::list_root_leaves(&self.uow())
            .map(|v| v.into_iter().map(leaf_meta_to_ffi).collect())
            .map_err(PinkhaError::from)
    }

    /// Lists direct children of a parent leaf. Used by the child-pages
    /// section in the leaf view and by the breadcrumbs picker.
    pub fn list_child_leaves(
        &self,
        parent_leaf_id: String,
    ) -> Result<Vec<LeafMetaFfi>, PinkhaError> {
        let parent = parse_uuid(&parent_leaf_id)?;
        use_cases::list_child_leaves(&self.uow(), parent)
            .map(|v| v.into_iter().map(leaf_meta_to_ffi).collect())
            .map_err(PinkhaError::from)
    }

    /// Returns the direct children of `parent_id` (`None` = root-level
    /// shelves). The filtering runs in Rust so callers never re-implement
    /// the parent/child query client-side.
    pub fn list_child_shelves(
        &self,
        parent_id: Option<String>,
    ) -> Result<Vec<ShelfMetaFfi>, PinkhaError> {
        let pid = parent_id.as_deref().map(parse_uuid).transpose()?;
        shelf_use_cases::list_child_shelves(&self.uow(), pid)
            .map(|v| v.into_iter().map(shelf_meta_to_ffi).collect())
            .map_err(PinkhaError::from)
    }
}
