use crate::application::error::PinkhaError;
use crate::application::unit_of_work::UnitOfWork;
use crate::domain::book::{Book, BookMeta, Entry, PropertyValue};
use crate::domain::leaf::InlineText;
use std::collections::HashMap;
use uuid::Uuid;

/// Creates a new book with the given title and properties, then persists it.
pub fn create_book(
    uow: &dyn UnitOfWork,
    title: Vec<InlineText>,
    properties: Vec<crate::domain::book::Property>,
) -> Result<Book, PinkhaError> {
    let db = Book::new(title, properties);
    uow.books().save(&db)?;
    Ok(db)
}

/// Variant of `create_book` that pins the book's `created_at` to a
/// specific timestamp (RFC 3339). Used by importers (Notion / Bear /
/// Craft) so the imported database carries its origin platform's
/// creation date through to the SQLite row — mirrors the leaf
/// treatment in [`super::super::use_cases::leaf::create_leaf_with_created_at`].
pub fn create_book_with_created_at(
    uow: &dyn UnitOfWork,
    title: Vec<InlineText>,
    properties: Vec<crate::domain::book::Property>,
    created_at: String,
) -> Result<Book, PinkhaError> {
    let mut db = Book::new(title, properties);
    db.created_at = Some(created_at);
    uow.books().save(&db)?;
    Ok(db)
}

/// Loads a full book by ID.
pub fn get_book(uow: &dyn UnitOfWork, id: Uuid) -> Result<Book, PinkhaError> {
    uow.books().load(id)
}

/// Returns lightweight metadata for all books (no entries loaded).
pub fn list_books(uow: &dyn UnitOfWork) -> Result<Vec<BookMeta>, PinkhaError> {
    uow.books().list_meta()
}

/// Soft-deletes a book by ID — recoverable via [`restore_book`].
pub fn delete_book(uow: &dyn UnitOfWork, book_id: Uuid) -> Result<(), PinkhaError> {
    uow.books().delete(book_id)
}

/// Lists soft-deleted books (newest-deleted first) — what the trash UI shows.
pub fn list_deleted_books(uow: &dyn UnitOfWork) -> Result<Vec<BookMeta>, PinkhaError> {
    uow.books().list_deleted()
}

/// Restores a soft-deleted book.
pub fn restore_book(uow: &dyn UnitOfWork, book_id: Uuid) -> Result<(), PinkhaError> {
    uow.books().restore(book_id)
}

/// Permanently deletes a soft-deleted book (hard delete).
pub fn purge_book(uow: &dyn UnitOfWork, book_id: Uuid) -> Result<(), PinkhaError> {
    uow.books().purge(book_id)
}

/// Replaces the rich-text title of a book. The new title is
/// already parsed into spans by the FFI layer.
pub fn update_book_title(
    uow: &dyn UnitOfWork,
    book_id: Uuid,
    title: Vec<InlineText>,
) -> Result<(), PinkhaError> {
    let repo = uow.books();
    let mut db = repo.load(book_id)?;
    // The lock is enforced here, not just in the UI — any future surface
    // (shortcuts, sync, new views) hits the same wall.
    if db.locked {
        return Err(PinkhaError::InvalidOperation("book is locked".to_string()));
    }
    db.title = title;
    repo.save(&db)
}

/// Replaces or clears the book's cover image identifier (URL or
/// local filename). `None` clears it.
pub fn update_book_cover(
    uow: &dyn UnitOfWork,
    book_id: Uuid,
    cover: Option<String>,
) -> Result<(), PinkhaError> {
    let repo = uow.books();
    let mut db = repo.load(book_id)?;
    db.cover = cover;
    repo.save(&db)
}

/// Replaces or clears the book's icon (emoji / filename / URL).
pub fn update_book_icon(
    uow: &dyn UnitOfWork,
    book_id: Uuid,
    icon: Option<String>,
) -> Result<(), PinkhaError> {
    let repo = uow.books();
    let mut db = repo.load(book_id)?;
    db.icon = icon;
    repo.save(&db)
}

/// Replaces the rich-text description of a book. Empty `Vec` is the
/// "no description" state and renders nothing in the header.
pub fn update_book_description(
    uow: &dyn UnitOfWork,
    book_id: Uuid,
    description: Vec<InlineText>,
) -> Result<(), PinkhaError> {
    let repo = uow.books();
    let mut db = repo.load(book_id)?;
    // Same wall as `update_book_title` — the lock is enforced at the
    // use-case layer, not just in the UI.
    if db.locked {
        return Err(PinkhaError::InvalidOperation("book is locked".to_string()));
    }
    db.description = description;
    repo.save(&db)
}

/// Flips the book's `locked` flag — read-only when `true`. The UI
/// uses this to disable every editor surface in one shot.
pub fn update_book_locked(
    uow: &dyn UnitOfWork,
    book_id: Uuid,
    locked: bool,
) -> Result<(), PinkhaError> {
    let repo = uow.books();
    let mut db = repo.load(book_id)?;
    db.locked = locked;
    repo.save(&db)
}

/// Adds a new row to the book and persists.
pub fn add_entry(
    uow: &dyn UnitOfWork,
    book_id: Uuid,
    values: HashMap<Uuid, PropertyValue>,
) -> Result<Entry, PinkhaError> {
    let repo = uow.books();
    let mut db = repo.load(book_id)?;
    let mut entry = Entry::new(values);
    if let Some(published) = db.source_publish_date(&entry.values) {
        entry.published_at = published;
    }
    db.entries.push(entry.clone());
    repo.save(&db)?;
    Ok(entry)
}

/// Adds a new row backed by an existing leaf. Used by import pipelines
/// where every imported page becomes both a Leaf and a book row, so
/// renaming the row in the DB view propagates to the leaf title (and
/// vice-versa, eventually).
pub fn add_entry_with_leaf(
    uow: &dyn UnitOfWork,
    book_id: Uuid,
    values: HashMap<Uuid, PropertyValue>,
    leaf_id: Uuid,
) -> Result<Entry, PinkhaError> {
    let repo = uow.books();
    let mut db = repo.load(book_id)?;
    let mut entry = Entry::with_leaf(values, leaf_id);
    if let Some(published) = db.source_publish_date(&entry.values) {
        entry.published_at = published;
    }
    db.entries.push(entry.clone());
    repo.save(&db)?;
    Ok(entry)
}

/// Variant of `add_entry_with_leaf` that pins the row's `created_at`
/// (and `published_at`, when no `published_at_source` is configured)
/// to a specific timestamp. Used by importers so each entry carries
/// the origin platform's per-row date instead of the import time —
/// mirrors `create_leaf_with_created_at` / `create_book_with_created_at`.
pub fn add_entry_with_leaf_and_created_at(
    uow: &dyn UnitOfWork,
    book_id: Uuid,
    values: HashMap<Uuid, PropertyValue>,
    leaf_id: Uuid,
    created_at: String,
) -> Result<Entry, PinkhaError> {
    let repo = uow.books();
    let mut db = repo.load(book_id)?;
    let mut entry = Entry::with_leaf(values, leaf_id);
    entry.created_at = created_at.clone();
    entry.published_at = created_at;
    if let Some(published) = db.source_publish_date(&entry.values) {
        entry.published_at = published;
    }
    db.entries.push(entry.clone());
    repo.save(&db)?;
    Ok(entry)
}

/// Overrides the `published_at` timestamp of an existing entry.
/// Empty string resets the entry to "follow `created_at`" (the
/// default behaviour). Used by the UI's publish-date picker.
pub fn update_entry_published_at(
    uow: &dyn UnitOfWork,
    book_id: Uuid,
    entry_id: Uuid,
    new_published_at: String,
) -> Result<(), PinkhaError> {
    let repo = uow.books();
    let mut db = repo.load(book_id)?;
    let entry = db
        .entries
        .iter_mut()
        .find(|e| e.id == entry_id)
        .ok_or(PinkhaError::NotFound(entry_id))?;
    entry.published_at = new_published_at;
    repo.save(&db)
}

/// Replaces all cell values for an existing entry and persists.
pub fn update_entry(
    uow: &dyn UnitOfWork,
    book_id: Uuid,
    entry_id: Uuid,
    values: HashMap<Uuid, PropertyValue>,
) -> Result<(), PinkhaError> {
    let repo = uow.books();
    let mut db = repo.load(book_id)?;
    let published = db.source_publish_date(&values);
    let entry = db
        .entries
        .iter_mut()
        .find(|e| e.id == entry_id)
        .ok_or(PinkhaError::NotFound(entry_id))?;
    entry.values = values;
    // Keep the publish date in lockstep with the source column (when one
    // is configured) so editing the date cell re-dates the row.
    if let Some(published) = published {
        entry.published_at = published;
    }
    repo.save(&db)
}

/// Soft-deletes an entry: marks it with a `deleted_at` timestamp instead of
/// removing it. The entry is hidden from `query`/`search`/`grouped_query` but
/// remains recoverable via [`restore_entry`] and can be permanently removed via
/// [`purge_entry`]. Returns `NotFound` when the entry is unknown or already
/// soft-deleted.
pub fn delete_entry(
    uow: &dyn UnitOfWork,
    book_id: Uuid,
    entry_id: Uuid,
) -> Result<(), PinkhaError> {
    let repo = uow.books();
    let mut db = repo.load(book_id)?;
    let entry = db
        .entries
        .iter_mut()
        .find(|e| e.id == entry_id && e.deleted_at.is_none())
        .ok_or(PinkhaError::NotFound(entry_id))?;
    entry.deleted_at = Some(chrono::Utc::now().to_rfc3339());
    repo.save(&db)
}

/// Restores a soft-deleted entry by clearing its `deleted_at` timestamp.
/// Returns `NotFound` when the entry doesn't exist or isn't currently soft-
/// deleted (nothing to restore).
pub fn restore_entry(
    uow: &dyn UnitOfWork,
    book_id: Uuid,
    entry_id: Uuid,
) -> Result<(), PinkhaError> {
    let repo = uow.books();
    let mut db = repo.load(book_id)?;
    let entry = db
        .entries
        .iter_mut()
        .find(|e| e.id == entry_id && e.deleted_at.is_some())
        .ok_or(PinkhaError::NotFound(entry_id))?;
    entry.deleted_at = None;
    repo.save(&db)
}

/// Permanently removes an entry from the book. Hard delete — the row is
/// gone after this returns. Only works on already-soft-deleted entries to
/// prevent accidental data loss; use [`delete_entry`] first, then `purge_entry`
/// from the trash UI.
pub fn purge_entry(uow: &dyn UnitOfWork, book_id: Uuid, entry_id: Uuid) -> Result<(), PinkhaError> {
    let repo = uow.books();
    let mut db = repo.load(book_id)?;
    match db.entries.iter().find(|e| e.id == entry_id) {
        None => return Err(PinkhaError::NotFound(entry_id)),
        Some(e) if e.deleted_at.is_none() => {
            return Err(PinkhaError::InvalidOperation(format!(
                "entry {entry_id} must be soft-deleted before it can be purged"
            )));
        }
        _ => {}
    }
    db.entries.retain(|e| e.id != entry_id);
    repo.save(&db)
}

/// Returns the soft-deleted entries of a book, sorted newest-deleted first.
/// Used by the trash UI to show what can be restored or purged.
pub fn list_deleted_entries(
    uow: &dyn UnitOfWork,
    book_id: Uuid,
) -> Result<Vec<crate::domain::book::Entry>, PinkhaError> {
    let db = uow.books().load(book_id)?;
    let mut deleted: Vec<_> = db.entries.into_iter().filter(|e| e.is_deleted()).collect();
    deleted.sort_by(|a, b| b.deleted_at.cmp(&a.deleted_at));
    Ok(deleted)
}
