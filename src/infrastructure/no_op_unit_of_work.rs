use crate::application::database_repository::DatabaseRepository;
use crate::application::error::PinkhaError;
use crate::application::folder_repository::FolderRepository;
use crate::application::repository::DocumentRepository;
use crate::application::unit_of_work::UnitOfWork;

/// A non-transactional `UnitOfWork` that simply borrows three independent
/// repositories.
///
/// `commit()` is a no-op — each repository write hits its own SQLite
/// connection in real time. This is the implementation used today; a future
/// `SqliteTransactionalUnitOfWork` (sharing a single connection + opening a
/// real `rusqlite::Transaction`) will provide true atomic cross-store writes
/// without changing any use-case signature.
pub struct NoOpUnitOfWork<'a> {
    docs: &'a dyn DocumentRepository,
    dbs: &'a dyn DatabaseRepository,
    folders: &'a dyn FolderRepository,
}

impl<'a> NoOpUnitOfWork<'a> {
    /// Wraps the three repositories without any transaction setup.
    pub fn new(
        docs: &'a dyn DocumentRepository,
        dbs: &'a dyn DatabaseRepository,
        folders: &'a dyn FolderRepository,
    ) -> Self {
        Self { docs, dbs, folders }
    }

    /// Partial constructor for callers (notably the import extractors) that
    /// only have document + database repos in scope. The folder accessor will
    /// panic if any use case reaches into it — by design: extractors must
    /// never touch folders. If a future use case does need folders, switch
    /// the caller to [`NoOpUnitOfWork::new`] instead.
    pub fn with_docs_dbs(
        docs: &'a dyn DocumentRepository,
        dbs: &'a dyn DatabaseRepository,
    ) -> Self {
        static PANIC_FOLDERS: PanickingFolderRepo = PanickingFolderRepo;
        Self {
            docs,
            dbs,
            folders: &PANIC_FOLDERS,
        }
    }

    /// Document-only partial constructor. Both other accessors panic on
    /// access — only call when the use case demonstrably touches only the
    /// document repository (e.g. `flush_document` in the Craft extractor).
    pub fn with_docs(docs: &'a dyn DocumentRepository) -> Self {
        static PANIC_DBS: PanickingDatabaseRepo = PanickingDatabaseRepo;
        static PANIC_FOLDERS: PanickingFolderRepo = PanickingFolderRepo;
        Self {
            docs,
            dbs: &PANIC_DBS,
            folders: &PANIC_FOLDERS,
        }
    }

    /// Database-only partial constructor. Both other accessors panic.
    pub fn with_dbs(dbs: &'a dyn DatabaseRepository) -> Self {
        static PANIC_DOCS: PanickingDocumentRepo = PanickingDocumentRepo;
        static PANIC_FOLDERS: PanickingFolderRepo = PanickingFolderRepo;
        Self {
            docs: &PANIC_DOCS,
            dbs,
            folders: &PANIC_FOLDERS,
        }
    }

    /// Folder-only partial constructor. Both other accessors panic.
    pub fn with_folders(folders: &'a dyn FolderRepository) -> Self {
        static PANIC_DOCS: PanickingDocumentRepo = PanickingDocumentRepo;
        static PANIC_DBS: PanickingDatabaseRepo = PanickingDatabaseRepo;
        Self {
            docs: &PANIC_DOCS,
            dbs: &PANIC_DBS,
            folders,
        }
    }
}

impl<'a> UnitOfWork for NoOpUnitOfWork<'a> {
    fn documents(&self) -> &dyn DocumentRepository {
        self.docs
    }

    fn databases(&self) -> &dyn DatabaseRepository {
        self.dbs
    }

    fn folders(&self) -> &dyn FolderRepository {
        self.folders
    }

    fn commit(self: Box<Self>) -> Result<(), PinkhaError> {
        Ok(())
    }
}

/// Placeholder document repository whose every method panics. Used as a
/// defensive default inside [`NoOpUnitOfWork::with_dbs`] / `with_folders`.
struct PanickingDocumentRepo;

impl DocumentRepository for PanickingDocumentRepo {
    fn save(&self, _: &crate::domain::document::Document) -> Result<(), PinkhaError> {
        panic!("documents repo not bound on this NoOpUnitOfWork");
    }
    fn load(&self, _: uuid::Uuid) -> Result<crate::domain::document::Document, PinkhaError> {
        panic!("documents repo not bound on this NoOpUnitOfWork");
    }
    fn list(&self) -> Result<Vec<crate::domain::document::DocumentMeta>, PinkhaError> {
        panic!("documents repo not bound on this NoOpUnitOfWork");
    }
    fn delete(&self, _: uuid::Uuid) -> Result<(), PinkhaError> {
        panic!("documents repo not bound on this NoOpUnitOfWork");
    }
    fn move_to_folder(&self, _: uuid::Uuid, _: Option<uuid::Uuid>) -> Result<(), PinkhaError> {
        panic!("documents repo not bound on this NoOpUnitOfWork");
    }
    fn list_by_folder(
        &self,
        _: Option<uuid::Uuid>,
    ) -> Result<Vec<crate::domain::document::DocumentMeta>, PinkhaError> {
        panic!("documents repo not bound on this NoOpUnitOfWork");
    }
}

/// Placeholder database repository whose every method panics. Used as a
/// defensive default inside [`NoOpUnitOfWork::with_docs`] — callers must
/// guarantee no use case reaches into it.
struct PanickingDatabaseRepo;

impl DatabaseRepository for PanickingDatabaseRepo {
    fn save(&self, _: &crate::domain::database::Database) -> Result<(), PinkhaError> {
        panic!("databases repo not bound on this NoOpUnitOfWork (constructed via with_docs)");
    }
    fn load(&self, _: uuid::Uuid) -> Result<crate::domain::database::Database, PinkhaError> {
        panic!("databases repo not bound on this NoOpUnitOfWork (constructed via with_docs)");
    }
    fn list_meta(&self) -> Result<Vec<crate::domain::database::DatabaseMeta>, PinkhaError> {
        panic!("databases repo not bound on this NoOpUnitOfWork (constructed via with_docs)");
    }
    fn delete(&self, _: uuid::Uuid) -> Result<(), PinkhaError> {
        panic!("databases repo not bound on this NoOpUnitOfWork (constructed via with_docs)");
    }
}

/// Placeholder folder repository whose every method panics. Used as a defensive
/// default inside [`NoOpUnitOfWork::with_docs_dbs`] — extractors don't operate
/// on folders today, so reaching this would indicate a logic error.
struct PanickingFolderRepo;

impl FolderRepository for PanickingFolderRepo {
    fn create(
        &self,
        _: &str,
        _: Option<uuid::Uuid>,
    ) -> Result<crate::domain::folder::Folder, PinkhaError> {
        panic!("folders repo not bound on this NoOpUnitOfWork (constructed via with_docs_dbs)");
    }
    fn get(&self, _: uuid::Uuid) -> Result<crate::domain::folder::Folder, PinkhaError> {
        panic!("folders repo not bound on this NoOpUnitOfWork (constructed via with_docs_dbs)");
    }
    fn list(&self) -> Result<Vec<crate::domain::folder::FolderMeta>, PinkhaError> {
        panic!("folders repo not bound on this NoOpUnitOfWork (constructed via with_docs_dbs)");
    }
    fn rename(&self, _: uuid::Uuid, _: &str) -> Result<(), PinkhaError> {
        panic!("folders repo not bound on this NoOpUnitOfWork (constructed via with_docs_dbs)");
    }
    fn delete(&self, _: uuid::Uuid) -> Result<(), PinkhaError> {
        panic!("folders repo not bound on this NoOpUnitOfWork (constructed via with_docs_dbs)");
    }
    fn move_folder(&self, _: uuid::Uuid, _: Option<uuid::Uuid>) -> Result<(), PinkhaError> {
        panic!("folders repo not bound on this NoOpUnitOfWork (constructed via with_docs_dbs)");
    }
}
