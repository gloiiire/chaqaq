use crate::application::book_repository::BookRepository;
use crate::application::error::PinkhaError;
use crate::application::shelf_repository::ShelfRepository;
use crate::application::repository::LeafRepository;
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
    docs: &'a dyn LeafRepository,
    dbs: &'a dyn BookRepository,
    shelves: &'a dyn ShelfRepository,
}

impl<'a> NoOpUnitOfWork<'a> {
    /// Wraps the three repositories without any transaction setup.
    pub fn new(
        docs: &'a dyn LeafRepository,
        dbs: &'a dyn BookRepository,
        shelves: &'a dyn ShelfRepository,
    ) -> Self {
        Self { docs, dbs, shelves }
    }

    /// Partial constructor for callers (notably the import extractors) that
    /// only have leaf + book repos in scope. The shelf accessor will
    /// panic if any use case reaches into it — by design: extractors must
    /// never touch shelves. If a future use case does need shelves, switch
    /// the caller to [`NoOpUnitOfWork::new`] instead.
    pub fn with_leaves_books(
        docs: &'a dyn LeafRepository,
        dbs: &'a dyn BookRepository,
    ) -> Self {
        static PANIC_FOLDERS: PanickingShelfRepo = PanickingShelfRepo;
        Self {
            docs,
            dbs,
            shelves: &PANIC_FOLDERS,
        }
    }

    /// Leaf-only partial constructor. Both other accessors panic on
    /// access — only call when the use case demonstrably touches only the
    /// leaf repository (e.g. `flush_leaf` in the Craft extractor).
    pub fn with_leaves(docs: &'a dyn LeafRepository) -> Self {
        static PANIC_DBS: PanickingBookRepo = PanickingBookRepo;
        static PANIC_FOLDERS: PanickingShelfRepo = PanickingShelfRepo;
        Self {
            docs,
            dbs: &PANIC_DBS,
            shelves: &PANIC_FOLDERS,
        }
    }

    /// Book-only partial constructor. Both other accessors panic.
    pub fn with_books(dbs: &'a dyn BookRepository) -> Self {
        static PANIC_DOCS: PanickingLeafRepo = PanickingLeafRepo;
        static PANIC_FOLDERS: PanickingShelfRepo = PanickingShelfRepo;
        Self {
            docs: &PANIC_DOCS,
            dbs,
            shelves: &PANIC_FOLDERS,
        }
    }

    /// Shelf-only partial constructor. Both other accessors panic.
    pub fn with_shelves(shelves: &'a dyn ShelfRepository) -> Self {
        static PANIC_DOCS: PanickingLeafRepo = PanickingLeafRepo;
        static PANIC_DBS: PanickingBookRepo = PanickingBookRepo;
        Self {
            docs: &PANIC_DOCS,
            dbs: &PANIC_DBS,
            shelves,
        }
    }
}

impl<'a> UnitOfWork for NoOpUnitOfWork<'a> {
    fn leaves(&self) -> &dyn LeafRepository {
        self.docs
    }

    fn books(&self) -> &dyn BookRepository {
        self.dbs
    }

    fn shelves(&self) -> &dyn ShelfRepository {
        self.shelves
    }

    fn commit(self: Box<Self>) -> Result<(), PinkhaError> {
        Ok(())
    }
}

/// Placeholder leaf repository whose every method panics. Used as a
/// defensive default inside [`NoOpUnitOfWork::with_books`] / `with_shelves`.
struct PanickingLeafRepo;

impl LeafRepository for PanickingLeafRepo {
    fn save(&self, _: &crate::domain::leaf::Leaf) -> Result<(), PinkhaError> {
        panic!("leaves repo not bound on this NoOpUnitOfWork");
    }
    fn load(&self, _: uuid::Uuid) -> Result<crate::domain::leaf::Leaf, PinkhaError> {
        panic!("leaves repo not bound on this NoOpUnitOfWork");
    }
    fn list(&self) -> Result<Vec<crate::domain::leaf::LeafMeta>, PinkhaError> {
        panic!("leaves repo not bound on this NoOpUnitOfWork");
    }
    fn delete(&self, _: uuid::Uuid) -> Result<(), PinkhaError> {
        panic!("leaves repo not bound on this NoOpUnitOfWork");
    }
    fn move_to_shelf(&self, _: uuid::Uuid, _: Option<uuid::Uuid>) -> Result<(), PinkhaError> {
        panic!("leaves repo not bound on this NoOpUnitOfWork");
    }
    fn list_by_shelf(
        &self,
        _: Option<uuid::Uuid>,
    ) -> Result<Vec<crate::domain::leaf::LeafMeta>, PinkhaError> {
        panic!("leaves repo not bound on this NoOpUnitOfWork");
    }
}

/// Placeholder book repository whose every method panics. Used as a
/// defensive default inside [`NoOpUnitOfWork::with_leaves`] — callers must
/// guarantee no use case reaches into it.
struct PanickingBookRepo;

impl BookRepository for PanickingBookRepo {
    fn save(&self, _: &crate::domain::book::Book) -> Result<(), PinkhaError> {
        panic!("books repo not bound on this NoOpUnitOfWork (constructed via with_leaves)");
    }
    fn load(&self, _: uuid::Uuid) -> Result<crate::domain::book::Book, PinkhaError> {
        panic!("books repo not bound on this NoOpUnitOfWork (constructed via with_leaves)");
    }
    fn list_meta(&self) -> Result<Vec<crate::domain::book::BookMeta>, PinkhaError> {
        panic!("books repo not bound on this NoOpUnitOfWork (constructed via with_leaves)");
    }
    fn delete(&self, _: uuid::Uuid) -> Result<(), PinkhaError> {
        panic!("books repo not bound on this NoOpUnitOfWork (constructed via with_leaves)");
    }
}

/// Placeholder shelf repository whose every method panics. Used as a defensive
/// default inside [`NoOpUnitOfWork::with_leaves_books`] — extractors don't operate
/// on shelves today, so reaching this would indicate a logic error.
struct PanickingShelfRepo;

impl ShelfRepository for PanickingShelfRepo {
    fn create(
        &self,
        _: &str,
        _: Option<uuid::Uuid>,
    ) -> Result<crate::domain::shelf::Shelf, PinkhaError> {
        panic!("shelves repo not bound on this NoOpUnitOfWork (constructed via with_leaves_books)");
    }
    fn get(&self, _: uuid::Uuid) -> Result<crate::domain::shelf::Shelf, PinkhaError> {
        panic!("shelves repo not bound on this NoOpUnitOfWork (constructed via with_leaves_books)");
    }
    fn list(&self) -> Result<Vec<crate::domain::shelf::ShelfMeta>, PinkhaError> {
        panic!("shelves repo not bound on this NoOpUnitOfWork (constructed via with_leaves_books)");
    }
    fn rename(&self, _: uuid::Uuid, _: &str) -> Result<(), PinkhaError> {
        panic!("shelves repo not bound on this NoOpUnitOfWork (constructed via with_leaves_books)");
    }
    fn delete(&self, _: uuid::Uuid) -> Result<(), PinkhaError> {
        panic!("shelves repo not bound on this NoOpUnitOfWork (constructed via with_leaves_books)");
    }
    fn move_shelf(&self, _: uuid::Uuid, _: Option<uuid::Uuid>) -> Result<(), PinkhaError> {
        panic!("shelves repo not bound on this NoOpUnitOfWork (constructed via with_leaves_books)");
    }
    fn update_icon(&self, _: uuid::Uuid, _: Option<&str>) -> Result<(), PinkhaError> {
        panic!("shelves repo not bound on this NoOpUnitOfWork (constructed via with_leaves_books)");
    }
}
