use crate::application::book_repository::BookRepository;
use crate::application::error::PinkhaError;
use crate::application::repository::LeafRepository;
use crate::application::shelf_repository::ShelfRepository;
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
    /// only have leaf + book repos in scope. The shelf accessor rejects
    /// every call — by design: extractors must never touch shelves. If a
    /// future use case does need shelves, switch the caller to
    /// [`NoOpUnitOfWork::new`] instead.
    pub fn with_leaves_books(docs: &'a dyn LeafRepository, dbs: &'a dyn BookRepository) -> Self {
        static UNBOUND_SHELVES: UnboundShelfRepo = UnboundShelfRepo;
        Self {
            docs,
            dbs,
            shelves: &UNBOUND_SHELVES,
        }
    }

    /// Leaf-only partial constructor. Both other accessors reject every
    /// call — only use when the use case demonstrably touches only the
    /// leaf repository (e.g. `flush_leaf` in the Craft extractor).
    pub fn with_leaves(docs: &'a dyn LeafRepository) -> Self {
        static UNBOUND_BOOKS: UnboundBookRepo = UnboundBookRepo;
        static UNBOUND_SHELVES: UnboundShelfRepo = UnboundShelfRepo;
        Self {
            docs,
            dbs: &UNBOUND_BOOKS,
            shelves: &UNBOUND_SHELVES,
        }
    }

    /// Book-only partial constructor. Both other accessors reject calls.
    pub fn with_books(dbs: &'a dyn BookRepository) -> Self {
        static UNBOUND_LEAVES: UnboundLeafRepo = UnboundLeafRepo;
        static UNBOUND_SHELVES: UnboundShelfRepo = UnboundShelfRepo;
        Self {
            docs: &UNBOUND_LEAVES,
            dbs,
            shelves: &UNBOUND_SHELVES,
        }
    }

    /// Shelf-only partial constructor. Both other accessors reject calls.
    pub fn with_shelves(shelves: &'a dyn ShelfRepository) -> Self {
        static UNBOUND_LEAVES: UnboundLeafRepo = UnboundLeafRepo;
        static UNBOUND_BOOKS: UnboundBookRepo = UnboundBookRepo;
        Self {
            docs: &UNBOUND_LEAVES,
            dbs: &UNBOUND_BOOKS,
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

/// Signals that a use case reached a repository its `UnitOfWork` was never
/// given.
///
/// These placeholders used to `panic!`. Every method here returns a
/// `Result`, so panicking was a choice rather than a necessity — and a bad
/// one on device: it aborts the whole app instead of failing the one import
/// that took the wrong path, turning a mis-wired constructor into a crash in
/// front of the user.
///
/// Deliberately not a `debug_assert!`: that would make the behaviour differ
/// between test and release builds, so the path that actually ships would be
/// the one no test ever runs. The message names both the repository and the
/// constructor that omitted it, which is the information a developer needs.
fn unbound(repo: &str, ctor: &str) -> PinkhaError {
    PinkhaError::InvalidOperation(format!(
        "{repo} repository is not available in this context ({ctor})"
    ))
}

/// Placeholder leaf repository: every method reports [`unbound`]. Used as a
/// defensive default inside [`NoOpUnitOfWork::with_books`] / `with_shelves`.
struct UnboundLeafRepo;

const LEAF_CTOR: &str = "constructed via with_books/with_shelves";

impl LeafRepository for UnboundLeafRepo {
    fn save(&self, _: &crate::domain::leaf::Leaf) -> Result<(), PinkhaError> {
        Err(unbound("leaves", LEAF_CTOR))
    }
    fn load(&self, _: uuid::Uuid) -> Result<crate::domain::leaf::Leaf, PinkhaError> {
        Err(unbound("leaves", LEAF_CTOR))
    }
    fn list(&self) -> Result<Vec<crate::domain::leaf::LeafMeta>, PinkhaError> {
        Err(unbound("leaves", LEAF_CTOR))
    }
    fn delete(&self, _: uuid::Uuid) -> Result<(), PinkhaError> {
        Err(unbound("leaves", LEAF_CTOR))
    }
    fn move_to_shelf(&self, _: uuid::Uuid, _: Option<uuid::Uuid>) -> Result<(), PinkhaError> {
        Err(unbound("leaves", LEAF_CTOR))
    }
    fn list_by_shelf(
        &self,
        _: Option<uuid::Uuid>,
    ) -> Result<Vec<crate::domain::leaf::LeafMeta>, PinkhaError> {
        Err(unbound("leaves", LEAF_CTOR))
    }
}

/// Placeholder book repository. Used as a defensive default inside
/// [`NoOpUnitOfWork::with_leaves`] — callers must guarantee no use case
/// reaches into it.
struct UnboundBookRepo;

const BOOK_CTOR: &str = "constructed via with_leaves/with_shelves";

impl BookRepository for UnboundBookRepo {
    fn save(&self, _: &crate::domain::book::Book) -> Result<(), PinkhaError> {
        Err(unbound("books", BOOK_CTOR))
    }
    fn load(&self, _: uuid::Uuid) -> Result<crate::domain::book::Book, PinkhaError> {
        Err(unbound("books", BOOK_CTOR))
    }
    fn list_meta(&self) -> Result<Vec<crate::domain::book::BookMeta>, PinkhaError> {
        Err(unbound("books", BOOK_CTOR))
    }
    fn delete(&self, _: uuid::Uuid) -> Result<(), PinkhaError> {
        Err(unbound("books", BOOK_CTOR))
    }
}

/// Placeholder shelf repository. Used as a defensive default inside
/// [`NoOpUnitOfWork::with_leaves_books`] — extractors don't operate on
/// shelves today, so reaching this indicates a logic error.
struct UnboundShelfRepo;

const SHELF_CTOR: &str = "constructed without a shelf repository";

impl ShelfRepository for UnboundShelfRepo {
    fn create(
        &self,
        _: &str,
        _: Option<uuid::Uuid>,
    ) -> Result<crate::domain::shelf::Shelf, PinkhaError> {
        Err(unbound("shelves", SHELF_CTOR))
    }
    fn get(&self, _: uuid::Uuid) -> Result<crate::domain::shelf::Shelf, PinkhaError> {
        Err(unbound("shelves", SHELF_CTOR))
    }
    fn list(&self) -> Result<Vec<crate::domain::shelf::ShelfMeta>, PinkhaError> {
        Err(unbound("shelves", SHELF_CTOR))
    }
    fn rename(&self, _: uuid::Uuid, _: &str) -> Result<(), PinkhaError> {
        Err(unbound("shelves", SHELF_CTOR))
    }
    fn delete(&self, _: uuid::Uuid) -> Result<(), PinkhaError> {
        Err(unbound("shelves", SHELF_CTOR))
    }
    fn move_shelf(&self, _: uuid::Uuid, _: Option<uuid::Uuid>) -> Result<(), PinkhaError> {
        Err(unbound("shelves", SHELF_CTOR))
    }
    fn update_icon(&self, _: uuid::Uuid, _: Option<&str>) -> Result<(), PinkhaError> {
        Err(unbound("shelves", SHELF_CTOR))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::infrastructure::sqlite_book_store::SqliteBookStore;
    use crate::infrastructure::sqlite_leaf_store::SqliteLeafStore;

    #[test]
    fn an_unbound_repo_returns_an_error_instead_of_aborting() {
        let leaves = SqliteLeafStore::in_memory().expect("store");
        let uow = NoOpUnitOfWork::with_leaves(&leaves);

        // Reaching for a repo this UoW was never given used to abort the
        // process. Being able to write this assertion at all is the fix.
        let err = uow.books().list_meta().unwrap_err();
        assert!(matches!(err, PinkhaError::InvalidOperation(_)), "{err:?}");
        assert!(err.to_string().contains("books"), "{err}");

        let err = uow.shelves().list().unwrap_err();
        assert!(err.to_string().contains("shelves"), "{err}");
    }

    #[test]
    fn the_message_names_the_constructor_that_omitted_the_repo() {
        let leaves = SqliteLeafStore::in_memory().expect("store");
        let uow = NoOpUnitOfWork::with_leaves(&leaves);
        // Without this, a developer sees "books unavailable" with no clue
        // which of the four constructors to switch away from.
        let text = uow.books().list_meta().unwrap_err().to_string();
        assert!(text.contains("with_leaves"), "{text}");
    }

    #[test]
    fn the_bound_repo_still_works_normally() {
        let leaves = SqliteLeafStore::in_memory().expect("store");
        let uow = NoOpUnitOfWork::with_leaves(&leaves);
        assert!(uow.leaves().list().is_ok());
    }

    #[test]
    fn every_partial_constructor_rejects_only_what_it_omitted() {
        let leaves = SqliteLeafStore::in_memory().expect("leaf store");
        let books = SqliteBookStore::in_memory().expect("book store");

        let uow = NoOpUnitOfWork::with_leaves_books(&leaves, &books);
        assert!(uow.leaves().list().is_ok());
        assert!(uow.books().list_meta().is_ok());
        assert!(uow.shelves().list().is_err());

        let uow = NoOpUnitOfWork::with_books(&books);
        assert!(uow.books().list_meta().is_ok());
        assert!(uow.leaves().list().is_err());
    }
}
