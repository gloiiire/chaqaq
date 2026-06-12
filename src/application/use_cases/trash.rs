//! Cross-domain trash operations spanning documents, databases and folders.

use crate::application::error::PinkhaError;
use crate::application::unit_of_work::UnitOfWork;
use crate::application::use_cases as doc_use_cases;
use crate::application::{database_use_cases, folder_use_cases};

/// Permanently purges every soft-deleted document, database and folder.
/// Returns the total number of items removed.
pub fn empty_trash(uow: &dyn UnitOfWork) -> Result<u32, PinkhaError> {
    let docs = doc_use_cases::list_deleted_documents(uow)?;
    let dbs = database_use_cases::list_deleted_databases(uow)?;
    let folders = folder_use_cases::list_deleted_folders(uow)?;

    for meta in &docs {
        doc_use_cases::purge_document(uow, meta.id)?;
    }
    for meta in &dbs {
        database_use_cases::purge_database(uow, meta.id)?;
    }
    for meta in &folders {
        folder_use_cases::purge_folder(uow, meta.id)?;
    }

    Ok((docs.len() + dbs.len() + folders.len()) as u32)
}
