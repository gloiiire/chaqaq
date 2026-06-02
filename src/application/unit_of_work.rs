use crate::application::database_repository::DatabaseRepository;
use crate::application::error::PinkhaError;
use crate::application::folder_repository::FolderRepository;
use crate::application::repository::DocumentRepository;

/// Groups the three repositories under a single unit of work boundary.
///
/// Use cases depend on `&dyn UnitOfWork` rather than individual repositories so
/// that they can compose cross-domain operations (e.g. renaming a document
/// because a database row's title changed) under a single atomicity boundary.
///
/// The current `NoOpUnitOfWork` implementation delegates to independent
/// stores (no real transactionality yet); the trait shape is what matters —
/// a future `SqliteTransactionalUnitOfWork` can swap in without touching the
/// use cases.
///
/// Lifecycle:
///   1. The composition root opens a UoW (`PinkhaApi::with_uow` does this).
///   2. The use case operates on the repositories via the UoW.
///   3. The composition root commits (`Box<dyn UnitOfWork>::commit`).
///   4. Dropping the UoW without commit is allowed — in transactional impls
///      it must rollback.
pub trait UnitOfWork {
    /// Document repository scoped to this unit of work.
    fn documents(&self) -> &dyn DocumentRepository;

    /// Database repository scoped to this unit of work.
    fn databases(&self) -> &dyn DatabaseRepository;

    /// Folder repository scoped to this unit of work.
    fn folders(&self) -> &dyn FolderRepository;

    /// Finalises the unit of work, persisting any pending changes.
    ///
    /// Consumes the boxed UoW so it can't be reused. Failure to commit
    /// (drop) means rollback for transactional implementations; no-op
    /// implementations make this a free operation.
    fn commit(self: Box<Self>) -> Result<(), PinkhaError>;
}

/// Test-only support: a `UnitOfWork` wrapper that takes any three repository
/// references. Any repo not provided panics on access — use this to force
/// honesty in test setups (a test that only exercises document use cases
/// must not silently reach into a stubbed database repo).
#[cfg(test)]
pub mod test_support {
    use super::*;

    /// Panics when its methods are called — used as a placeholder repository
    /// in test UoWs that should never reach the other domains.
    pub struct PanickingDocumentRepo;
    pub struct PanickingDatabaseRepo;
    pub struct PanickingFolderRepo;

    impl DocumentRepository for PanickingDocumentRepo {
        fn save(&self, _: &crate::domain::document::Document) -> Result<(), PinkhaError> {
            unreachable!("documents repo not provided to this MockUnitOfWork");
        }
        fn load(&self, _: uuid::Uuid) -> Result<crate::domain::document::Document, PinkhaError> {
            unreachable!("documents repo not provided to this MockUnitOfWork");
        }
        fn list(&self) -> Result<Vec<crate::domain::document::DocumentMeta>, PinkhaError> {
            unreachable!("documents repo not provided to this MockUnitOfWork");
        }
        fn delete(&self, _: uuid::Uuid) -> Result<(), PinkhaError> {
            unreachable!("documents repo not provided to this MockUnitOfWork");
        }
        fn move_to_folder(&self, _: uuid::Uuid, _: Option<uuid::Uuid>) -> Result<(), PinkhaError> {
            unreachable!("documents repo not provided to this MockUnitOfWork");
        }
        fn list_by_folder(
            &self,
            _: Option<uuid::Uuid>,
        ) -> Result<Vec<crate::domain::document::DocumentMeta>, PinkhaError> {
            unreachable!("documents repo not provided to this MockUnitOfWork");
        }
    }

    impl DatabaseRepository for PanickingDatabaseRepo {
        fn save(&self, _: &crate::domain::database::Database) -> Result<(), PinkhaError> {
            unreachable!("databases repo not provided to this MockUnitOfWork");
        }
        fn load(&self, _: uuid::Uuid) -> Result<crate::domain::database::Database, PinkhaError> {
            unreachable!("databases repo not provided to this MockUnitOfWork");
        }
        fn list_meta(&self) -> Result<Vec<crate::domain::database::DatabaseMeta>, PinkhaError> {
            unreachable!("databases repo not provided to this MockUnitOfWork");
        }
        fn delete(&self, _: uuid::Uuid) -> Result<(), PinkhaError> {
            unreachable!("databases repo not provided to this MockUnitOfWork");
        }
    }

    impl FolderRepository for PanickingFolderRepo {
        fn create(
            &self,
            _: &str,
            _: Option<uuid::Uuid>,
        ) -> Result<crate::domain::folder::Folder, PinkhaError> {
            unreachable!("folders repo not provided to this MockUnitOfWork");
        }
        fn get(&self, _: uuid::Uuid) -> Result<crate::domain::folder::Folder, PinkhaError> {
            unreachable!("folders repo not provided to this MockUnitOfWork");
        }
        fn list(&self) -> Result<Vec<crate::domain::folder::FolderMeta>, PinkhaError> {
            unreachable!("folders repo not provided to this MockUnitOfWork");
        }
        fn rename(&self, _: uuid::Uuid, _: &str) -> Result<(), PinkhaError> {
            unreachable!("folders repo not provided to this MockUnitOfWork");
        }
        fn delete(&self, _: uuid::Uuid) -> Result<(), PinkhaError> {
            unreachable!("folders repo not provided to this MockUnitOfWork");
        }
        fn move_folder(&self, _: uuid::Uuid, _: Option<uuid::Uuid>) -> Result<(), PinkhaError> {
            unreachable!("folders repo not provided to this MockUnitOfWork");
        }
    }

    /// A `UnitOfWork` for tests that selectively provides each repository.
    /// Repos left as `None` panic on access via the corresponding accessor.
    pub struct MockUnitOfWork<'a> {
        pub docs: Option<&'a dyn DocumentRepository>,
        pub dbs: Option<&'a dyn DatabaseRepository>,
        pub folders: Option<&'a dyn FolderRepository>,
    }

    impl<'a> MockUnitOfWork<'a> {
        pub fn with_docs(docs: &'a dyn DocumentRepository) -> Self {
            Self {
                docs: Some(docs),
                dbs: None,
                folders: None,
            }
        }

        pub fn with_dbs(dbs: &'a dyn DatabaseRepository) -> Self {
            Self {
                docs: None,
                dbs: Some(dbs),
                folders: None,
            }
        }

        pub fn with_folders(folders: &'a dyn FolderRepository) -> Self {
            Self {
                docs: None,
                dbs: None,
                folders: Some(folders),
            }
        }

        pub fn all(
            docs: &'a dyn DocumentRepository,
            dbs: &'a dyn DatabaseRepository,
            folders: &'a dyn FolderRepository,
        ) -> Self {
            Self {
                docs: Some(docs),
                dbs: Some(dbs),
                folders: Some(folders),
            }
        }
    }

    impl<'a> UnitOfWork for MockUnitOfWork<'a> {
        fn documents(&self) -> &dyn DocumentRepository {
            match self.docs {
                Some(d) => d,
                None => {
                    static PANIC: PanickingDocumentRepo = PanickingDocumentRepo;
                    &PANIC
                }
            }
        }

        fn databases(&self) -> &dyn DatabaseRepository {
            match self.dbs {
                Some(d) => d,
                None => {
                    static PANIC: PanickingDatabaseRepo = PanickingDatabaseRepo;
                    &PANIC
                }
            }
        }

        fn folders(&self) -> &dyn FolderRepository {
            match self.folders {
                Some(f) => f,
                None => {
                    static PANIC: PanickingFolderRepo = PanickingFolderRepo;
                    &PANIC
                }
            }
        }

        fn commit(self: Box<Self>) -> Result<(), PinkhaError> {
            Ok(())
        }
    }
}
