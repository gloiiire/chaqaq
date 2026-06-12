//! Folder operations and document/folder placement on the [`PinkhaApi`] facade.

use crate::application::{folder_use_cases, use_cases};

use super::types::{DocumentMetaFfi, FolderMetaFfi, doc_meta_to_ffi, folder_meta_to_ffi};
use super::validation::{parse_uuid, validate_string};
use super::{PinkhaApi, PinkhaError};

impl PinkhaApi {
    // ── Folders ───────────────────────────────────────────────────────────────

    pub fn create_folder(
        &self,
        name: String,
        parent_id: Option<String>,
    ) -> Result<FolderMetaFfi, PinkhaError> {
        validate_string(&name, "name")?;
        let pid = parent_id.as_deref().map(parse_uuid).transpose()?;
        let folder =
            folder_use_cases::create_folder(&self.uow(), &name, pid).map_err(PinkhaError::from)?;
        Ok(folder_meta_to_ffi((&folder).into()))
    }

    pub fn get_folder(&self, id: String) -> Result<FolderMetaFfi, PinkhaError> {
        let uuid = parse_uuid(&id)?;
        let folder = folder_use_cases::get_folder(&self.uow(), uuid).map_err(PinkhaError::from)?;
        Ok(folder_meta_to_ffi((&folder).into()))
    }

    pub fn list_folders(&self) -> Result<Vec<FolderMetaFfi>, PinkhaError> {
        folder_use_cases::list_folders(&self.uow())
            .map(|v| v.into_iter().map(folder_meta_to_ffi).collect())
            .map_err(PinkhaError::from)
    }

    pub fn rename_folder(&self, id: String, new_name: String) -> Result<(), PinkhaError> {
        validate_string(&new_name, "new_name")?;
        let uuid = parse_uuid(&id)?;
        folder_use_cases::rename_folder(&self.uow(), uuid, &new_name).map_err(PinkhaError::from)
    }

    /// Sets or clears a folder's emoji icon. Pass `None` to remove.
    pub fn update_folder_icon(&self, id: String, icon: Option<String>) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        folder_use_cases::update_folder_icon(&self.uow(), uuid, icon.as_deref())
            .map_err(PinkhaError::from)
    }

    pub fn delete_folder(&self, id: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        folder_use_cases::delete_folder(&self.uow(), uuid).map_err(PinkhaError::from)
    }

    /// Soft-deletes every folder. Documents and databases that lived inside
    /// are orphaned to the root (the `delete_folder` use case handles that).
    /// Returns the number of folders deleted.
    pub fn delete_all_folders(&self) -> Result<u32, PinkhaError> {
        let metas = folder_use_cases::list_folders(&self.uow()).map_err(PinkhaError::from)?;
        let count = metas.len() as u32;
        for meta in metas {
            folder_use_cases::delete_folder(&self.uow(), meta.id).map_err(PinkhaError::from)?;
        }
        Ok(count)
    }

    /// Lists soft-deleted folders (the trash). Newest-deleted first.
    pub fn list_deleted_folders(&self) -> Result<Vec<FolderMetaFfi>, PinkhaError> {
        folder_use_cases::list_deleted_folders(&self.uow())
            .map(|v| v.into_iter().map(folder_meta_to_ffi).collect())
            .map_err(PinkhaError::from)
    }

    /// Restores a soft-deleted folder.
    pub fn restore_folder(&self, id: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        folder_use_cases::restore_folder(&self.uow(), uuid).map_err(PinkhaError::from)
    }

    /// Permanently deletes a soft-deleted folder (purge from trash).
    pub fn purge_folder(&self, id: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        folder_use_cases::purge_folder(&self.uow(), uuid).map_err(PinkhaError::from)
    }

    pub fn move_folder_to(
        &self,
        id: String,
        new_parent_id: Option<String>,
    ) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        let pid = new_parent_id.as_deref().map(parse_uuid).transpose()?;
        folder_use_cases::move_folder(&self.uow(), uuid, pid).map_err(PinkhaError::from)
    }

    pub fn move_document_to_folder(
        &self,
        doc_id: String,
        folder_id: Option<String>,
    ) -> Result<(), PinkhaError> {
        let doc_uuid = parse_uuid(&doc_id)?;
        let fid = folder_id.as_deref().map(parse_uuid).transpose()?;
        use_cases::move_document_to_folder(&self.uow(), doc_uuid, fid).map_err(PinkhaError::from)
    }

    pub fn list_documents_in_folder(
        &self,
        folder_id: Option<String>,
    ) -> Result<Vec<DocumentMetaFfi>, PinkhaError> {
        let fid = folder_id.as_deref().map(parse_uuid).transpose()?;
        use_cases::list_documents_in_folder(&self.uow(), fid)
            .map(|v| v.into_iter().map(doc_meta_to_ffi).collect())
            .map_err(PinkhaError::from)
    }

    /// Sets the parent document for page-in-page hierarchy. Pass `None`
    /// to promote the document back to root. Rejects cycles.
    pub fn update_document_parent(
        &self,
        doc_id: String,
        new_parent_doc_id: Option<String>,
    ) -> Result<(), PinkhaError> {
        let doc_uuid = parse_uuid(&doc_id)?;
        let parent = new_parent_doc_id.as_deref().map(parse_uuid).transpose()?;
        use_cases::update_document_parent(&self.uow(), doc_uuid, parent).map_err(PinkhaError::from)
    }

    /// Lists root pages (documents with no parent). Drives the home view.
    pub fn list_root_documents(&self) -> Result<Vec<DocumentMetaFfi>, PinkhaError> {
        use_cases::list_root_documents(&self.uow())
            .map(|v| v.into_iter().map(doc_meta_to_ffi).collect())
            .map_err(PinkhaError::from)
    }

    /// Lists direct children of a parent document. Used by the child-pages
    /// section in the document view and by the breadcrumbs picker.
    pub fn list_child_documents(
        &self,
        parent_doc_id: String,
    ) -> Result<Vec<DocumentMetaFfi>, PinkhaError> {
        let parent = parse_uuid(&parent_doc_id)?;
        use_cases::list_child_documents(&self.uow(), parent)
            .map(|v| v.into_iter().map(doc_meta_to_ffi).collect())
            .map_err(PinkhaError::from)
    }

    /// Returns the direct children of `parent_id` (`None` = root-level
    /// folders). The filtering runs in Rust so callers never re-implement
    /// the parent/child query client-side.
    pub fn list_child_folders(
        &self,
        parent_id: Option<String>,
    ) -> Result<Vec<FolderMetaFfi>, PinkhaError> {
        let pid = parent_id.as_deref().map(parse_uuid).transpose()?;
        folder_use_cases::list_child_folders(&self.uow(), pid)
            .map(|v| v.into_iter().map(folder_meta_to_ffi).collect())
            .map_err(PinkhaError::from)
    }
}
