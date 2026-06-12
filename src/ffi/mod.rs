//! UniFFI facade: the [`PinkhaApi`] object plus the FFI-facing error and
//! dictionary types. Composition root of the application — the only layer
//! allowed to know concrete store implementations.
//!
//! Method implementations are grouped by domain:
//! - [`documents`] — documents, blocks, search, document trash
//! - [`databases`] — databases, entries, properties, views, queries
//! - [`folders`] — folders and document placement
//! - [`workspace`] — cross-domain operations (super search, empty trash)
//! - [`extractors`] — Notion / Bear / Craft import endpoints

mod databases;
mod documents;
mod error;
mod extractors;
mod folders;
mod types;
mod validation;
mod workspace;

pub use error::PinkhaError;
pub use types::{
    BlockSearchHitFfi, DatabaseMetaFfi, DocumentMetaFfi, FolderMetaFfi, ImportResultFfi,
    NotionDatabaseSummaryFfi, SuperSearchResultsFfi,
};

use crate::infrastructure::no_op_unit_of_work::NoOpUnitOfWork;
use crate::infrastructure::sqlite_database_store::SqliteDatabaseStore;
use crate::infrastructure::sqlite_document_store::SqliteDocumentStore;
use crate::infrastructure::sqlite_folder_store::SqliteFolderStore;

/// Top-level API exposed to Swift via UniFFI.
///
/// Opens both the document and database SQLite stores at the same file path
/// and exposes all CRUD operations for documents, blocks, and databases.
/// Blocks and full databases cross the boundary as JSON strings (Swift decodes
/// them with `Codable`) to avoid expressing recursive types in the UDL.
pub struct PinkhaApi {
    docs: SqliteDocumentStore,
    dbs: SqliteDatabaseStore,
    folders: SqliteFolderStore,
}

impl PinkhaApi {
    /// Creates a new API instance backed by a SQLite file at `db_path`.
    pub fn new(db_path: String) -> Result<Self, PinkhaError> {
        let docs = SqliteDocumentStore::new(&db_path).map_err(PinkhaError::from)?;
        let dbs = SqliteDatabaseStore::new(&db_path).map_err(PinkhaError::from)?;
        let folders = SqliteFolderStore::new(&db_path).map_err(PinkhaError::from)?;
        Ok(Self { docs, dbs, folders })
    }

    /// Opens a non-transactional unit of work that borrows the three
    /// repositories. Use cases consume `&dyn UnitOfWork`; this is the bridge
    /// that wires the composition root to each call. The returned UoW's
    /// `commit()` is a no-op (the underlying stores write through their own
    /// SQLite connections); a future transactional impl will swap in here.
    fn uow(&self) -> NoOpUnitOfWork<'_> {
        NoOpUnitOfWork::new(&self.docs, &self.dbs, &self.folders)
    }
}
