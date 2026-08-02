//! Cross-domain orchestration between the book and leaf repositories.
//!
//! Lives at the application layer so it can depend on **both** `&dyn
//! LeafRepository` and `&dyn BookRepository` without coupling either
//! domain to the other. The FFI composition root wires concrete stores in.

use std::collections::HashMap;
use uuid::Uuid;

use crate::application::book_use_cases;
use crate::application::error::PinkhaError;
use crate::application::unit_of_work::UnitOfWork;
use crate::application::use_cases as leaf_use_cases;
use crate::domain::book::{PropertyType, PropertyValue};

/// Updates a book entry's values and — when the row is backed by a
/// leaf (`entry.leaf_id` is `Some`) and the supplied values touch the
/// book's Title property — propagates the new title to the underlying
/// leaf.
///
/// Fixes the long-standing UX bug where renaming a row in the book view
/// left the corresponding note's name untouched. Idempotent: re-applying the
/// same title is a no-op writer-side because `update_leaf_title` always
/// re-parses and re-saves.
///
/// Truly cross-domain: touches both the book repository (for the entry
/// update) and the leaf repository (for the title propagation). When the
/// underlying `UnitOfWork` is transactional, both writes commit or roll back
/// together.
pub fn update_entry_propagating_title(
    uow: &dyn UnitOfWork,
    book_id: Uuid,
    entry_id: Uuid,
    values: HashMap<Uuid, PropertyValue>,
) -> Result<(), PinkhaError> {
    // Capture the entry's leaf link and the book's Title property
    // before we mutate anything — the post-write reload would still give us
    // the same data, but doing it upfront keeps the function easy to read.
    let db = uow.books().load(book_id)?;
    let leaf_id = db
        .entries
        .iter()
        .find(|e| e.id == entry_id)
        .ok_or(PinkhaError::NotFound(entry_id))?
        .leaf_id;
    let title_prop_id = db
        .properties
        .iter()
        .find(|p| matches!(p.type_, PropertyType::Title))
        .map(|p| p.id);

    // Perform the entry update.
    book_use_cases::update_entry(uow, book_id, entry_id, values.clone())?;

    // Propagate to the leaf title when applicable.
    //
    // `NotFound` is swallowed on both propagations below: `Entry.leaf_id`
    // can dangle when the backing leaf was trashed or purged while its row
    // stayed in the book. The entry write above is already committed, so
    // propagating a `NotFound` upward would report the whole edit as failed
    // while it actually persisted — the UI would then show a stale value
    // that "comes back" on the next reload. Same treatment as
    // `delete_book_cascade` / `restore_book_cascade` / `set_published_at_source`.
    if let (Some(leaf_id), Some(title_id)) = (leaf_id, title_prop_id)
        && let Some(PropertyValue::Title(spans)) = values.get(&title_id)
    {
        let plain: String = spans.iter().map(|t| t.content.as_str()).collect();
        match leaf_use_cases::update_leaf_title(uow, leaf_id, &plain) {
            Ok(()) | Err(PinkhaError::NotFound(_)) => {}
            Err(e) => return Err(e),
        }
    }

    // Propagate the publish date when the book has a source column —
    // `update_entry` already synced the entry's `published_at`; the
    // backing leaf follows so home-view sorts agree with the DB view.
    if let (Some(leaf_id), Some(published)) = (leaf_id, db.source_publish_date(&values)) {
        match leaf_use_cases::update_leaf_published_at(uow, leaf_id, published) {
            Ok(()) | Err(PinkhaError::NotFound(_)) => {}
            Err(e) => return Err(e),
        }
    }

    Ok(())
}

/// Soft-deletes a shelf together with every leaf filed in it AND every
/// sub-shelf (recursively, with their own leaves). Used by the
/// "Delete shelf & contents" confirmation — the alternative
/// `delete_shelf` keeps the contents alive by reparenting them. Returns
/// the total number of leaves deleted alongside, summed across all
/// descendant shelves.
pub fn delete_shelf_cascade(uow: &dyn UnitOfWork, shelf_id: Uuid) -> Result<u32, PinkhaError> {
    use crate::application::shelf_use_cases;
    let mut deleted: u32 = 0;
    // Walk the shelf tree breadth-first so sub-shelves' leaves are
    // gathered before their parent shelf is deleted (the SQLite
    // store's `delete_shelf` reparents sub-shelves to the parent ;
    // running the cascade in order avoids losing track of them).
    let mut queue: Vec<Uuid> = vec![shelf_id];
    let mut all_shelves: Vec<Uuid> = Vec::new();
    while let Some(current) = queue.pop() {
        all_shelves.push(current);
        let children = shelf_use_cases::list_child_shelves(uow, Some(current))?;
        for c in children {
            queue.push(c.id);
        }
    }
    // Delete deepest shelves first so the parent's `delete` doesn't
    // reparent children we're about to wipe.
    for shelf_id in all_shelves.iter().rev() {
        // Trash every leaf filed directly under this shelf.
        let leaves = leaf_use_cases::list_leaves_in_shelf(uow, Some(*shelf_id))?;
        for leaf in leaves {
            match leaf_use_cases::delete_leaf(uow, leaf.id) {
                Ok(()) => deleted += 1,
                Err(PinkhaError::NotFound(_)) => {}
                Err(e) => return Err(e),
            }
        }
        shelf_use_cases::delete_shelf(uow, *shelf_id)?;
    }
    Ok(deleted)
}

/// Soft-deletes a book together with every leaf its rows are
/// backed by (`Entry.leaf_id`). Leaves already in the trash are
/// skipped. Returns the number of leaves deleted alongside the
/// book — the UI surfaces it in the confirmation feedback.
pub fn delete_book_cascade(uow: &dyn UnitOfWork, book_id: Uuid) -> Result<u32, PinkhaError> {
    // Load before deleting — `load` only sees active books.
    let db = uow.books().load(book_id)?;
    let leaf_ids: Vec<Uuid> = db.entries.iter().filter_map(|e| e.leaf_id).collect();
    book_use_cases::delete_book(uow, book_id)?;

    let mut deleted: u32 = 0;
    for leaf_id in leaf_ids {
        match leaf_use_cases::delete_leaf(uow, leaf_id) {
            Ok(()) => deleted += 1,
            // Already trashed or purged — nothing left to delete.
            Err(PinkhaError::NotFound(_)) => {}
            Err(e) => return Err(e),
        }
    }
    Ok(deleted)
}

/// Restores a soft-deleted book together with every leaf its
/// rows are backed by. Leaves that are not in the trash (still
/// active, or purged for good) are skipped. Returns the number of
/// leaves restored alongside the book.
pub fn restore_book_cascade(uow: &dyn UnitOfWork, book_id: Uuid) -> Result<u32, PinkhaError> {
    // Restore first — `load` only sees active books.
    book_use_cases::restore_book(uow, book_id)?;
    let db = uow.books().load(book_id)?;

    let mut restored: u32 = 0;
    for leaf_id in db.entries.iter().filter_map(|e| e.leaf_id) {
        match leaf_use_cases::restore_leaf(uow, leaf_id) {
            Ok(()) => restored += 1,
            // Active (nothing to restore) or purged (nothing left).
            Err(PinkhaError::NotFound(_)) => {}
            Err(e) => return Err(e),
        }
    }
    Ok(restored)
}

/// Sets (or clears with `None`) the Date column that drives every row's
/// `published_at` in this book, then re-syncs all rows:
/// - adopting a column backfills `published_at` on each entry from the
///   column's cell (empty cell = empty sentinel = "follow `created_at`"),
/// - clearing resets every entry back to the sentinel.
///
/// Backing leaves follow their entry so the home view's "Published"
/// sort agrees with the book view. Rows pointing at trashed
/// leaves are skipped silently. Returns the number of entries whose
/// `published_at` changed.
pub fn set_published_at_source(
    uow: &dyn UnitOfWork,
    book_id: Uuid,
    source: Option<Uuid>,
) -> Result<u32, PinkhaError> {
    let repo = uow.books();
    let mut db = repo.load(book_id)?;

    if let Some(prop_id) = source {
        let prop = db
            .properties
            .iter()
            .find(|p| p.id == prop_id)
            .ok_or(PinkhaError::NotFound(prop_id))?;
        if !matches!(prop.type_, PropertyType::Date) {
            return Err(PinkhaError::InvalidOperation(
                "published_at_source must be a Date property".to_string(),
            ));
        }
    }
    db.published_at_source = source;

    let mut touched: u32 = 0;
    let mut leaf_updates: Vec<(Uuid, String)> = Vec::new();
    for entry in &mut db.entries {
        // With a source column the cell's date wins (empty cell = empty
        // sentinel); with the source cleared every row resets to the
        // sentinel and follows its creation date again.
        let new_published = db
            .published_at_source
            .and_then(|prop_id| match entry.values.get(&prop_id) {
                Some(PropertyValue::Date(d)) if !d.is_empty() => Some(d.clone()),
                _ => None,
            })
            .unwrap_or_default();
        if entry.published_at != new_published {
            entry.published_at = new_published.clone();
            touched += 1;
        }
        if let Some(leaf_id) = entry.leaf_id {
            leaf_updates.push((leaf_id, new_published));
        }
    }
    repo.save(&db)?;

    for (leaf_id, published) in leaf_updates {
        match leaf_use_cases::update_leaf_published_at(uow, leaf_id, published) {
            Ok(()) => {}
            // The entry may point at a soft-deleted leaf — its
            // publish date will be re-derived if it ever gets restored.
            Err(PinkhaError::NotFound(_)) => {}
            Err(e) => return Err(e),
        }
    }
    Ok(touched)
}

/// Creates a fresh leaf and files it as a new row of `book_id` in one
/// operation — the book "+" button and the create-note-in-book
/// sheet both go through here.
///
/// On top of the caller-provided `extra_values`, two columns are filled
/// automatically when the book defines them:
/// - the hidden [`PAGE_LINK_PROPERTY`] Text column receives the new
///   leaf's UUID (Notion-style "row = page" back-link),
/// - the Title column receives `title` as a single plain span.
///
/// The entry also stores `leaf_id` so title edits propagate through
/// [`update_entry_propagating_title`]. Returns `(leaf_id, entry_id)`.
pub fn create_leaf_in_book(
    uow: &dyn UnitOfWork,
    book_id: Uuid,
    title: &str,
    extra_values: HashMap<Uuid, PropertyValue>,
) -> Result<(Uuid, Uuid), PinkhaError> {
    use crate::domain::book::PAGE_LINK_PROPERTY;
    use crate::domain::leaf::InlineText;

    // Load the schema first so a bad `book_id` fails before any write.
    let db = uow.books().load(book_id)?;

    let doc = leaf_use_cases::create_leaf(uow, title)?;

    let mut values = extra_values;
    if let Some(page_prop) = db.properties.iter().find(|p| p.name == PAGE_LINK_PROPERTY) {
        values.insert(page_prop.id, PropertyValue::Text(doc.id.to_string()));
    }
    if let Some(title_prop) = db
        .properties
        .iter()
        .find(|p| matches!(p.type_, PropertyType::Title))
    {
        let spans = if title.is_empty() {
            vec![]
        } else {
            vec![InlineText {
                content: title.to_string(),
                styles: vec![],
            }]
        };
        values.insert(title_prop.id, PropertyValue::Title(spans));
    }

    let entry = book_use_cases::add_entry_with_leaf(uow, book_id, values, doc.id)?;
    Ok((doc.id, entry.id))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::application::book_repository::BookRepository;
    use crate::application::repository::LeafRepository;
    use crate::application::unit_of_work::test_support::MockUnitOfWork;
    use crate::domain::book::{Book, Property, PropertyType};
    use crate::domain::leaf::{Leaf, InlineText};

    use std::collections::HashMap;

    // ── Minimal in-memory mocks ────────────────────────────────────────────

    struct MockDocRepo {
        docs: std::sync::Mutex<HashMap<Uuid, Leaf>>,
    }
    impl MockDocRepo {
        fn new() -> Self {
            Self {
                docs: std::sync::Mutex::new(HashMap::new()),
            }
        }
        fn seed(&self, doc: Leaf) {
            self.docs.lock().unwrap().insert(doc.id, doc);
        }
    }
    impl LeafRepository for MockDocRepo {
        fn save(&self, doc: &Leaf) -> Result<(), PinkhaError> {
            self.docs.lock().unwrap().insert(doc.id, doc.clone());
            Ok(())
        }
        fn load(&self, id: Uuid) -> Result<Leaf, PinkhaError> {
            self.docs
                .lock()
                .unwrap()
                .get(&id)
                .cloned()
                .ok_or(PinkhaError::NotFound(id))
        }
        fn list(&self) -> Result<Vec<crate::domain::leaf::LeafMeta>, PinkhaError> {
            Ok(self
                .docs
                .lock()
                .unwrap()
                .values()
                .map(crate::domain::leaf::LeafMeta::from)
                .collect())
        }
        fn delete(&self, id: Uuid) -> Result<(), PinkhaError> {
            self.docs
                .lock()
                .unwrap()
                .remove(&id)
                .map(|_| ())
                .ok_or(PinkhaError::NotFound(id))
        }
        fn move_to_shelf(&self, _: Uuid, _: Option<Uuid>) -> Result<(), PinkhaError> {
            Ok(())
        }
        fn list_by_shelf(
            &self,
            _: Option<Uuid>,
        ) -> Result<Vec<crate::domain::leaf::LeafMeta>, PinkhaError> {
            self.list()
        }
    }

    struct MockDbRepo {
        dbs: std::sync::Mutex<HashMap<Uuid, Book>>,
    }
    impl MockDbRepo {
        fn new() -> Self {
            Self {
                dbs: std::sync::Mutex::new(HashMap::new()),
            }
        }
        fn seed(&self, db: Book) {
            self.dbs.lock().unwrap().insert(db.id, db);
        }
    }
    impl BookRepository for MockDbRepo {
        fn save(&self, db: &Book) -> Result<(), PinkhaError> {
            self.dbs.lock().unwrap().insert(db.id, db.clone());
            Ok(())
        }
        fn load(&self, id: Uuid) -> Result<Book, PinkhaError> {
            self.dbs
                .lock()
                .unwrap()
                .get(&id)
                .cloned()
                .ok_or(PinkhaError::NotFound(id))
        }
        fn list_meta(&self) -> Result<Vec<crate::domain::book::BookMeta>, PinkhaError> {
            Ok(self
                .dbs
                .lock()
                .unwrap()
                .values()
                .map(|db| db.meta())
                .collect())
        }
        fn delete(&self, id: Uuid) -> Result<(), PinkhaError> {
            self.dbs
                .lock()
                .unwrap()
                .remove(&id)
                .map(|_| ())
                .ok_or(PinkhaError::NotFound(id))
        }
    }

    fn span(text: &str) -> Vec<InlineText> {
        vec![InlineText {
            content: text.into(),
            styles: vec![],
        }]
    }

    fn seed_book_with_title_prop(repo: &MockDbRepo) -> (Uuid, Uuid) {
        let title_prop = Property::new("Name", PropertyType::Title);
        let title_prop_id = title_prop.id;
        let db = Book::new(span("Tasks"), vec![title_prop]);
        let book_id = db.id;
        repo.seed(db);
        (book_id, title_prop_id)
    }

    // ── Tests ──────────────────────────────────────────────────────────────

    #[test]
    fn renames_leaf_when_entry_is_backed_by_one() {
        let docs = MockDocRepo::new();
        let dbs = MockDbRepo::new();
        let (book_id, title_prop_id) = seed_book_with_title_prop(&dbs);

        // Seed a leaf the entry points to.
        let doc = Leaf::new(span("Old title"));
        let leaf_id = doc.id;
        docs.seed(doc);

        // Add a row linked to that leaf.
        let initial_values: HashMap<Uuid, PropertyValue> =
            HashMap::from([(title_prop_id, PropertyValue::Title(span("Old title")))]);
        let entry = book_use_cases::add_entry_with_leaf(
            &MockUnitOfWork::with_books(&dbs),
            book_id,
            initial_values,
            leaf_id,
        )
        .unwrap();

        // Rename the row.
        let new_values: HashMap<Uuid, PropertyValue> =
            HashMap::from([(title_prop_id, PropertyValue::Title(span("Brand new title")))]);
        update_entry_propagating_title(
            &MockUnitOfWork {
                docs: Some(&docs),
                dbs: Some(&dbs),
                shelves: None,
            },
            book_id,
            entry.id,
            new_values,
        )
        .unwrap();

        // Leaf was renamed under the hood.
        let updated_leaf = docs.load(leaf_id).unwrap();
        let plain: String = updated_leaf
            .title
            .iter()
            .map(|s| s.content.as_str())
            .collect();
        assert_eq!(plain, "Brand new title");
    }

    #[test]
    fn leaves_leaf_alone_when_entry_has_no_leaf_link() {
        let docs = MockDocRepo::new();
        let dbs = MockDbRepo::new();
        let (book_id, title_prop_id) = seed_book_with_title_prop(&dbs);

        // Standalone leaf — must not be touched even with the same UUID space.
        let doc = Leaf::new(span("Untouched"));
        let leaf_id = doc.id;
        docs.seed(doc);

        // Row with no leaf_id (standalone tabular data).
        let initial_values: HashMap<Uuid, PropertyValue> =
            HashMap::from([(title_prop_id, PropertyValue::Title(span("row title")))]);
        let entry =
            book_use_cases::add_entry(&MockUnitOfWork::with_books(&dbs), book_id, initial_values)
                .unwrap();

        let new_values: HashMap<Uuid, PropertyValue> =
            HashMap::from([(title_prop_id, PropertyValue::Title(span("renamed row")))]);
        update_entry_propagating_title(
            &MockUnitOfWork {
                docs: Some(&docs),
                dbs: Some(&dbs),
                shelves: None,
            },
            book_id,
            entry.id,
            new_values,
        )
        .unwrap();

        // Original doc unchanged — sanity check.
        let untouched = docs.load(leaf_id).unwrap();
        let plain: String = untouched.title.iter().map(|s| s.content.as_str()).collect();
        assert_eq!(plain, "Untouched");
    }

    #[test]
    fn no_op_when_values_do_not_include_title_property() {
        let docs = MockDocRepo::new();
        let dbs = MockDbRepo::new();
        let (book_id, title_prop_id) = seed_book_with_title_prop(&dbs);

        let doc = Leaf::new(span("Stable title"));
        let leaf_id = doc.id;
        docs.seed(doc);

        let initial_values: HashMap<Uuid, PropertyValue> =
            HashMap::from([(title_prop_id, PropertyValue::Title(span("Stable title")))]);
        let entry = book_use_cases::add_entry_with_leaf(
            &MockUnitOfWork::with_books(&dbs),
            book_id,
            initial_values,
            leaf_id,
        )
        .unwrap();

        // Update some non-Title property (the same Title slot left out entirely).
        let new_values: HashMap<Uuid, PropertyValue> = HashMap::new();
        update_entry_propagating_title(
            &MockUnitOfWork {
                docs: Some(&docs),
                dbs: Some(&dbs),
                shelves: None,
            },
            book_id,
            entry.id,
            new_values,
        )
        .unwrap();

        // Leaf title is untouched.
        let untouched = docs.load(leaf_id).unwrap();
        let plain: String = untouched.title.iter().map(|s| s.content.as_str()).collect();
        assert_eq!(plain, "Stable title");
    }

    #[test]
    fn returns_not_found_for_unknown_entry() {
        let docs = MockDocRepo::new();
        let dbs = MockDbRepo::new();
        let (book_id, _) = seed_book_with_title_prop(&dbs);

        let res = update_entry_propagating_title(
            &MockUnitOfWork {
                docs: Some(&docs),
                dbs: Some(&dbs),
                shelves: None,
            },
            book_id,
            Uuid::new_v4(),
            HashMap::new(),
        );
        assert!(matches!(res, Err(PinkhaError::NotFound(_))));
    }
}
