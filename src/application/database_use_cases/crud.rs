use crate::application::error::PinkhaError;
use crate::application::unit_of_work::UnitOfWork;
use crate::domain::database::{Database, DatabaseMeta, Entry, PropertyValue};
use crate::domain::document::InlineText;
use std::collections::HashMap;
use uuid::Uuid;

/// Creates a new database with the given title and properties, then persists it.
pub fn create_database(
    uow: &dyn UnitOfWork,
    title: Vec<InlineText>,
    properties: Vec<crate::domain::database::Property>,
) -> Result<Database, PinkhaError> {
    let db = Database::new(title, properties);
    uow.databases().save(&db)?;
    Ok(db)
}

/// Loads a full database by ID.
pub fn get_database(uow: &dyn UnitOfWork, id: Uuid) -> Result<Database, PinkhaError> {
    uow.databases().load(id)
}

/// Returns lightweight metadata for all databases (no entries loaded).
pub fn list_databases(uow: &dyn UnitOfWork) -> Result<Vec<DatabaseMeta>, PinkhaError> {
    uow.databases().list_meta()
}

/// Soft-deletes a database by ID — recoverable via [`restore_database`].
pub fn delete_database(uow: &dyn UnitOfWork, db_id: Uuid) -> Result<(), PinkhaError> {
    uow.databases().delete(db_id)
}

/// Lists soft-deleted databases (newest-deleted first) — what the trash UI shows.
pub fn list_deleted_databases(uow: &dyn UnitOfWork) -> Result<Vec<DatabaseMeta>, PinkhaError> {
    uow.databases().list_deleted()
}

/// Restores a soft-deleted database.
pub fn restore_database(uow: &dyn UnitOfWork, db_id: Uuid) -> Result<(), PinkhaError> {
    uow.databases().restore(db_id)
}

/// Permanently deletes a soft-deleted database (hard delete).
pub fn purge_database(uow: &dyn UnitOfWork, db_id: Uuid) -> Result<(), PinkhaError> {
    uow.databases().purge(db_id)
}

/// Replaces the rich-text title of a database. The new title is
/// already parsed into spans by the FFI layer.
pub fn update_database_title(
    uow: &dyn UnitOfWork,
    db_id: Uuid,
    title: Vec<InlineText>,
) -> Result<(), PinkhaError> {
    let repo = uow.databases();
    let mut db = repo.load(db_id)?;
    db.title = title;
    repo.save(&db)
}

/// Replaces or clears the database's cover image identifier (URL or
/// local filename). `None` clears it.
pub fn update_database_cover(
    uow: &dyn UnitOfWork,
    db_id: Uuid,
    cover: Option<String>,
) -> Result<(), PinkhaError> {
    let repo = uow.databases();
    let mut db = repo.load(db_id)?;
    db.cover = cover;
    repo.save(&db)
}

/// Replaces or clears the database's icon (emoji / filename / URL).
pub fn update_database_icon(
    uow: &dyn UnitOfWork,
    db_id: Uuid,
    icon: Option<String>,
) -> Result<(), PinkhaError> {
    let repo = uow.databases();
    let mut db = repo.load(db_id)?;
    db.icon = icon;
    repo.save(&db)
}

/// Replaces the rich-text description of a database. Empty `Vec` is the
/// "no description" state and renders nothing in the header.
pub fn update_database_description(
    uow: &dyn UnitOfWork,
    db_id: Uuid,
    description: Vec<InlineText>,
) -> Result<(), PinkhaError> {
    let repo = uow.databases();
    let mut db = repo.load(db_id)?;
    db.description = description;
    repo.save(&db)
}

/// Adds a new row to the database and persists.
pub fn add_entry(
    uow: &dyn UnitOfWork,
    db_id: Uuid,
    values: HashMap<Uuid, PropertyValue>,
) -> Result<Entry, PinkhaError> {
    let repo = uow.databases();
    let mut db = repo.load(db_id)?;
    let entry = Entry::new(values);
    db.entries.push(entry.clone());
    repo.save(&db)?;
    Ok(entry)
}

/// Adds a new row backed by an existing document. Used by import pipelines
/// where every imported page becomes both a Document and a database row, so
/// renaming the row in the DB view propagates to the document title (and
/// vice-versa, eventually).
pub fn add_entry_with_document(
    uow: &dyn UnitOfWork,
    db_id: Uuid,
    values: HashMap<Uuid, PropertyValue>,
    document_id: Uuid,
) -> Result<Entry, PinkhaError> {
    let repo = uow.databases();
    let mut db = repo.load(db_id)?;
    let entry = Entry::with_document(values, document_id);
    db.entries.push(entry.clone());
    repo.save(&db)?;
    Ok(entry)
}

/// Replaces all cell values for an existing entry and persists.
pub fn update_entry(
    uow: &dyn UnitOfWork,
    db_id: Uuid,
    entry_id: Uuid,
    values: HashMap<Uuid, PropertyValue>,
) -> Result<(), PinkhaError> {
    let repo = uow.databases();
    let mut db = repo.load(db_id)?;
    let entry = db
        .entries
        .iter_mut()
        .find(|e| e.id == entry_id)
        .ok_or(PinkhaError::NotFound(entry_id))?;
    entry.values = values;
    repo.save(&db)
}

/// Soft-deletes an entry: marks it with a `deleted_at` timestamp instead of
/// removing it. The entry is hidden from `query`/`search`/`grouped_query` but
/// remains recoverable via [`restore_entry`] and can be permanently removed via
/// [`purge_entry`]. Returns `NotFound` when the entry is unknown or already
/// soft-deleted.
pub fn delete_entry(uow: &dyn UnitOfWork, db_id: Uuid, entry_id: Uuid) -> Result<(), PinkhaError> {
    let repo = uow.databases();
    let mut db = repo.load(db_id)?;
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
pub fn restore_entry(uow: &dyn UnitOfWork, db_id: Uuid, entry_id: Uuid) -> Result<(), PinkhaError> {
    let repo = uow.databases();
    let mut db = repo.load(db_id)?;
    let entry = db
        .entries
        .iter_mut()
        .find(|e| e.id == entry_id && e.deleted_at.is_some())
        .ok_or(PinkhaError::NotFound(entry_id))?;
    entry.deleted_at = None;
    repo.save(&db)
}

/// Permanently removes an entry from the database. Hard delete — the row is
/// gone after this returns. Only works on already-soft-deleted entries to
/// prevent accidental data loss; use [`delete_entry`] first, then `purge_entry`
/// from the trash UI.
pub fn purge_entry(uow: &dyn UnitOfWork, db_id: Uuid, entry_id: Uuid) -> Result<(), PinkhaError> {
    let repo = uow.databases();
    let mut db = repo.load(db_id)?;
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

/// Returns the soft-deleted entries of a database, sorted newest-deleted first.
/// Used by the trash UI to show what can be restored or purged.
pub fn list_deleted_entries(
    uow: &dyn UnitOfWork,
    db_id: Uuid,
) -> Result<Vec<crate::domain::database::Entry>, PinkhaError> {
    let db = uow.databases().load(db_id)?;
    let mut deleted: Vec<_> = db.entries.into_iter().filter(|e| e.is_deleted()).collect();
    deleted.sort_by(|a, b| b.deleted_at.cmp(&a.deleted_at));
    Ok(deleted)
}
