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

/// Deletes a database by ID.
pub fn delete_database(uow: &dyn UnitOfWork, db_id: Uuid) -> Result<(), PinkhaError> {
    uow.databases().delete(db_id)
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

/// Removes an entry from the database and persists.
pub fn delete_entry(uow: &dyn UnitOfWork, db_id: Uuid, entry_id: Uuid) -> Result<(), PinkhaError> {
    let repo = uow.databases();
    let mut db = repo.load(db_id)?;
    let before = db.entries.len();
    db.entries.retain(|e| e.id != entry_id);
    if db.entries.len() == before {
        return Err(PinkhaError::NotFound(entry_id));
    }
    repo.save(&db)
}
