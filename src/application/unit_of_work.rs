use crate::application::book_repository::BookRepository;
use crate::application::error::PinkhaError;
use crate::application::repository::LeafRepository;
use crate::application::shelf_repository::ShelfRepository;

/// Groups the three repositories under a single unit of work boundary.
///
/// Use cases depend on `&dyn UnitOfWork` rather than individual repositories so
/// that they can compose cross-domain operations (e.g. renaming a leaf
/// because a book row's title changed) under a single atomicity boundary.
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
    /// Leaf repository scoped to this unit of work.
    fn leaves(&self) -> &dyn LeafRepository;

    /// Book repository scoped to this unit of work.
    fn books(&self) -> &dyn BookRepository;

    /// Shelf repository scoped to this unit of work.
    fn shelves(&self) -> &dyn ShelfRepository;

    /// Finalises the unit of work, persisting any pending changes.
    ///
    /// Consumes the boxed UoW so it can't be reused. Failure to commit
    /// (drop) means rollback for transactional implementations; no-op
    /// implementations make this a free operation.
    fn commit(self: Box<Self>) -> Result<(), PinkhaError>;
}

/// Test-only support: a `UnitOfWork` wrapper that takes any three repository
/// references. Any repo not provided panics on access — use this to force
/// honesty in test setups (a test that only exercises leaf use cases
/// must not silently reach into a stubbed book repo).
#[cfg(test)]
pub mod test_support {
    use super::*;

    /// Panics when its methods are called — used as a placeholder repository
    /// in test UoWs that should never reach the other domains.
    pub struct PanickingLeafRepo;
    pub struct PanickingBookRepo;
    pub struct PanickingShelfRepo;

    impl LeafRepository for PanickingLeafRepo {
        fn save(&self, _: &crate::domain::leaf::Leaf) -> Result<(), PinkhaError> {
            unreachable!("leaves repo not provided to this MockUnitOfWork");
        }
        fn load(&self, _: uuid::Uuid) -> Result<crate::domain::leaf::Leaf, PinkhaError> {
            unreachable!("leaves repo not provided to this MockUnitOfWork");
        }
        fn list(&self) -> Result<Vec<crate::domain::leaf::LeafMeta>, PinkhaError> {
            unreachable!("leaves repo not provided to this MockUnitOfWork");
        }
        fn delete(&self, _: uuid::Uuid) -> Result<(), PinkhaError> {
            unreachable!("leaves repo not provided to this MockUnitOfWork");
        }
        fn move_to_shelf(&self, _: uuid::Uuid, _: Option<uuid::Uuid>) -> Result<(), PinkhaError> {
            unreachable!("leaves repo not provided to this MockUnitOfWork");
        }
        fn list_by_shelf(
            &self,
            _: Option<uuid::Uuid>,
        ) -> Result<Vec<crate::domain::leaf::LeafMeta>, PinkhaError> {
            unreachable!("leaves repo not provided to this MockUnitOfWork");
        }
    }

    impl BookRepository for PanickingBookRepo {
        fn save(&self, _: &crate::domain::book::Book) -> Result<(), PinkhaError> {
            unreachable!("books repo not provided to this MockUnitOfWork");
        }
        fn load(&self, _: uuid::Uuid) -> Result<crate::domain::book::Book, PinkhaError> {
            unreachable!("books repo not provided to this MockUnitOfWork");
        }
        fn list_meta(&self) -> Result<Vec<crate::domain::book::BookMeta>, PinkhaError> {
            unreachable!("books repo not provided to this MockUnitOfWork");
        }
        fn delete(&self, _: uuid::Uuid) -> Result<(), PinkhaError> {
            unreachable!("books repo not provided to this MockUnitOfWork");
        }
    }

    impl ShelfRepository for PanickingShelfRepo {
        fn create(
            &self,
            _: &str,
            _: Option<uuid::Uuid>,
        ) -> Result<crate::domain::shelf::Shelf, PinkhaError> {
            unreachable!("shelves repo not provided to this MockUnitOfWork");
        }
        fn get(&self, _: uuid::Uuid) -> Result<crate::domain::shelf::Shelf, PinkhaError> {
            unreachable!("shelves repo not provided to this MockUnitOfWork");
        }
        fn list(&self) -> Result<Vec<crate::domain::shelf::ShelfMeta>, PinkhaError> {
            unreachable!("shelves repo not provided to this MockUnitOfWork");
        }
        fn rename(&self, _: uuid::Uuid, _: &str) -> Result<(), PinkhaError> {
            unreachable!("shelves repo not provided to this MockUnitOfWork");
        }
        fn delete(&self, _: uuid::Uuid) -> Result<(), PinkhaError> {
            unreachable!("shelves repo not provided to this MockUnitOfWork");
        }
        fn move_shelf(&self, _: uuid::Uuid, _: Option<uuid::Uuid>) -> Result<(), PinkhaError> {
            unreachable!("shelves repo not provided to this MockUnitOfWork");
        }
        fn update_icon(&self, _: uuid::Uuid, _: Option<&str>) -> Result<(), PinkhaError> {
            unreachable!("shelves repo not provided to this MockUnitOfWork");
        }
    }

    /// A `UnitOfWork` for tests that selectively provides each repository.
    /// Repos left as `None` panic on access via the corresponding accessor.
    pub struct MockUnitOfWork<'a> {
        pub docs: Option<&'a dyn LeafRepository>,
        pub dbs: Option<&'a dyn BookRepository>,
        pub shelves: Option<&'a dyn ShelfRepository>,
    }

    impl<'a> MockUnitOfWork<'a> {
        pub fn with_leaves(docs: &'a dyn LeafRepository) -> Self {
            Self {
                docs: Some(docs),
                dbs: None,
                shelves: None,
            }
        }

        pub fn with_books(dbs: &'a dyn BookRepository) -> Self {
            Self {
                docs: None,
                dbs: Some(dbs),
                shelves: None,
            }
        }

        pub fn with_shelves(shelves: &'a dyn ShelfRepository) -> Self {
            Self {
                docs: None,
                dbs: None,
                shelves: Some(shelves),
            }
        }

        pub fn all(
            docs: &'a dyn LeafRepository,
            dbs: &'a dyn BookRepository,
            shelves: &'a dyn ShelfRepository,
        ) -> Self {
            Self {
                docs: Some(docs),
                dbs: Some(dbs),
                shelves: Some(shelves),
            }
        }
    }

    impl<'a> UnitOfWork for MockUnitOfWork<'a> {
        fn leaves(&self) -> &dyn LeafRepository {
            match self.docs {
                Some(d) => d,
                None => {
                    static PANIC: PanickingLeafRepo = PanickingLeafRepo;
                    &PANIC
                }
            }
        }

        fn books(&self) -> &dyn BookRepository {
            match self.dbs {
                Some(d) => d,
                None => {
                    static PANIC: PanickingBookRepo = PanickingBookRepo;
                    &PANIC
                }
            }
        }

        fn shelves(&self) -> &dyn ShelfRepository {
            match self.shelves {
                Some(f) => f,
                None => {
                    static PANIC: PanickingShelfRepo = PanickingShelfRepo;
                    &PANIC
                }
            }
        }

        fn commit(self: Box<Self>) -> Result<(), PinkhaError> {
            Ok(())
        }
    }
}
