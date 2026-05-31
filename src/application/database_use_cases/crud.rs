use crate::application::database_repository::DatabaseRepository;
use crate::application::error::PinkhaError;
use crate::domain::database::{Database, DatabaseMeta, Entry, PropertyValue};
use crate::domain::document::InlineText;
use std::collections::HashMap;
use uuid::Uuid;

/// Creates a new database with the given title and properties, then persists it.
pub fn create_database(
    repo: &dyn DatabaseRepository,
    title: Vec<InlineText>,
    properties: Vec<crate::domain::database::Property>,
) -> Result<Database, PinkhaError> {
    let db = Database::new(title, properties);
    repo.save(&db)?;
    Ok(db)
}

/// Loads a full database by ID.
pub fn get_database(repo: &dyn DatabaseRepository, id: Uuid) -> Result<Database, PinkhaError> {
    repo.load(id)
}

/// Returns lightweight metadata for all databases (no entries loaded).
pub fn list_databases(repo: &dyn DatabaseRepository) -> Result<Vec<DatabaseMeta>, PinkhaError> {
    repo.list_meta()
}

/// Deletes a database by ID.
pub fn delete_database(repo: &dyn DatabaseRepository, db_id: Uuid) -> Result<(), PinkhaError> {
    repo.delete(db_id)
}

/// Adds a new row to the database and persists.
pub fn add_entry(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    values: HashMap<Uuid, PropertyValue>,
) -> Result<Entry, PinkhaError> {
    let mut db = repo.load(db_id)?;
    let entry = Entry::new(values);
    db.entries.push(entry.clone());
    repo.save(&db)?;
    Ok(entry)
}

/// Replaces all cell values for an existing entry and persists.
pub fn update_entry(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    entry_id: Uuid,
    values: HashMap<Uuid, PropertyValue>,
) -> Result<(), PinkhaError> {
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
pub fn delete_entry(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    entry_id: Uuid,
) -> Result<(), PinkhaError> {
    let mut db = repo.load(db_id)?;
    let before = db.entries.len();
    db.entries.retain(|e| e.id != entry_id);
    if db.entries.len() == before {
        return Err(PinkhaError::NotFound(entry_id));
    }
    repo.save(&db)
}
