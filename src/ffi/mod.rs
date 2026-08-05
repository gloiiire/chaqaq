//! UniFFI facade: the [`PinkhaApi`] object plus the FFI-facing error and
//! dictionary types. Composition root of the application — the only layer
//! allowed to know concrete store implementations.
//!
//! Method implementations are grouped by domain:
//! - [`leaves`] — leaves, blocks, search, leaf trash
//! - [`books`] — books, entries, properties, views, queries
//! - [`shelves`] — shelves and leaf placement
//! - [`library`] — cross-domain operations (super search, empty trash)
//! - [`extractors`] — Notion / Bear / Craft import endpoints

mod books;
mod error;
mod extractors;
mod leaves;
mod library;
mod shelves;
mod types;
mod validation;

pub use error::PinkhaError;
pub use types::{
    BlockSearchHitFfi, BookMetaFfi, BulkOutcomeFfi, ImportResultFfi, LeafMetaFfi,
    LibrarySnapshotFfi, NotionDatabaseSummaryFfi, NotionPageSummaryFfi, ShelfMetaFfi,
    SuperSearchResultsFfi,
};

use uuid::Uuid;

use crate::infrastructure::no_op_unit_of_work::NoOpUnitOfWork;
use crate::infrastructure::sqlite_book_store::SqliteBookStore;
use crate::infrastructure::sqlite_leaf_store::SqliteLeafStore;
use crate::infrastructure::sqlite_shelf_store::SqliteShelfStore;

/// Top-level API exposed to Swift via UniFFI.
///
/// Opens both the leaf and book SQLite stores at the same file path
/// and exposes all CRUD operations for leaves, blocks, and books.
/// Blocks and full books cross the boundary as JSON strings (Swift decodes
/// them with `Codable`) to avoid expressing recursive types in the UDL.
pub struct PinkhaApi {
    docs: SqliteLeafStore,
    dbs: SqliteBookStore,
    shelves: SqliteShelfStore,
}

impl PinkhaApi {
    /// Creates a new API instance backed by a SQLite file at `db_path`.
    ///
    /// The three stores each open their own connection to the same path.
    /// For a real file that is exactly one shared database — but a bare
    /// `":memory:"` gives every connection its own *private* database, so
    /// the leaf, book and shelf stores would silently stop seeing each
    /// other. Any cross-store statement (e.g. `ShelfStore::purge` re-homing
    /// the leaves that referenced the shelf) would then be a no-op, and a
    /// whole class of bug becomes structurally invisible to tests.
    ///
    /// So `":memory:"` is rewritten to a uniquely-named *shared-cache*
    /// in-memory URI: one database, three connections, same semantics as a
    /// file — while staying isolated from any other `PinkhaApi` in the same
    /// process. The database lives as long as a connection is open, which
    /// here is the lifetime of `self`.
    pub fn new(db_path: String) -> Result<Self, PinkhaError> {
        let resolved = if db_path == ":memory:" {
            format!(
                "file:pinkha-mem-{}?mode=memory&cache=shared",
                Uuid::new_v4()
            )
        } else {
            db_path
        };
        let docs = SqliteLeafStore::new(&resolved).map_err(PinkhaError::from)?;
        let dbs = SqliteBookStore::new(&resolved).map_err(PinkhaError::from)?;
        let shelves = SqliteShelfStore::new(&resolved).map_err(PinkhaError::from)?;
        Ok(Self { docs, dbs, shelves })
    }

    /// Opens a non-transactional unit of work that borrows the three
    /// repositories. Use cases consume `&dyn UnitOfWork`; this is the bridge
    /// that wires the composition root to each call. The returned UoW's
    /// `commit()` is a no-op (the underlying stores write through their own
    /// SQLite connections); a future transactional impl will swap in here.
    fn uow(&self) -> NoOpUnitOfWork<'_> {
        NoOpUnitOfWork::new(&self.docs, &self.dbs, &self.shelves)
    }
}
