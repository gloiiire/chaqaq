use crate::application::error::PinkhaError;
use crate::application::unit_of_work::UnitOfWork;
use crate::domain::database::Property;
use uuid::Uuid;

/// Adds a new column definition to the database and persists.
pub fn add_property(
    uow: &dyn UnitOfWork,
    db_id: Uuid,
    property: Property,
) -> Result<(), PinkhaError> {
    let repo = uow.databases();
    let mut db = repo.load(db_id)?;
    db.properties.push(property);
    repo.save(&db)
}

/// Renames an existing property and persists.
pub fn rename_property(
    uow: &dyn UnitOfWork,
    db_id: Uuid,
    prop_id: Uuid,
    new_name: &str,
) -> Result<(), PinkhaError> {
    let repo = uow.databases();
    let mut db = repo.load(db_id)?;
    let prop = db
        .properties
        .iter_mut()
        .find(|p| p.id == prop_id)
        .ok_or(PinkhaError::NotFound(prop_id))?;
    prop.name = new_name.to_string();
    repo.save(&db)
}

/// Removes a property column and clears its values from all existing entries, then persists.
pub fn delete_property(
    uow: &dyn UnitOfWork,
    db_id: Uuid,
    prop_id: Uuid,
) -> Result<(), PinkhaError> {
    let repo = uow.databases();
    let mut db = repo.load(db_id)?;
    let before = db.properties.len();
    db.properties.retain(|p| p.id != prop_id);
    if db.properties.len() == before {
        return Err(PinkhaError::NotFound(prop_id));
    }
    for entry in &mut db.entries {
        entry.values.remove(&prop_id);
    }
    repo.save(&db)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::application::database_repository::DatabaseRepository;
    use crate::application::error::PinkhaError;
    use crate::application::unit_of_work::test_support::MockUnitOfWork;
    use crate::domain::database::{Database, DatabaseMeta, Entry, PropertyType, PropertyValue};
    use crate::domain::document::InlineText;

    use std::collections::HashMap;
    use uuid::Uuid;

    struct MockDbRepo {
        dbs: std::sync::Mutex<std::collections::HashMap<Uuid, Database>>,
    }

    impl MockDbRepo {
        fn new() -> Self {
            Self {
                dbs: std::sync::Mutex::new(std::collections::HashMap::new()),
            }
        }
    }

    impl DatabaseRepository for MockDbRepo {
        fn save(&self, db: &Database) -> Result<(), PinkhaError> {
            self.dbs.lock().unwrap().insert(db.id, db.clone());
            Ok(())
        }
        fn load(&self, id: Uuid) -> Result<Database, PinkhaError> {
            self.dbs
                .lock()
                .unwrap()
                .get(&id)
                .cloned()
                .ok_or(PinkhaError::NotFound(id))
        }
        fn list_meta(&self) -> Result<Vec<DatabaseMeta>, PinkhaError> {
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

    fn title(s: &str) -> Vec<InlineText> {
        vec![InlineText {
            content: s.to_string(),
            styles: vec![],
        }]
    }

    fn db_uow(repo: &MockDbRepo) -> MockUnitOfWork<'_> {
        MockUnitOfWork::with_dbs(repo)
    }

    #[test]
    fn test_rename_property() {
        let repo = MockDbRepo::new();
        let prop = Property::new("Ancien", PropertyType::Text);
        let prop_id = prop.id;
        let db = Database::new(title("DB"), vec![prop]);
        repo.save(&db).unwrap();

        rename_property(&db_uow(&repo), db.id, prop_id, "Nouveau").unwrap();

        let db = repo.load(db.id).unwrap();
        assert_eq!(db.properties[0].name, "Nouveau");
    }

    #[test]
    fn test_rename_property_inexistante_erreur() {
        let repo = MockDbRepo::new();
        let db = Database::new(title("DB"), vec![]);
        repo.save(&db).unwrap();

        let res = rename_property(&db_uow(&repo), db.id, Uuid::new_v4(), "X");
        assert!(matches!(res, Err(PinkhaError::NotFound(_))));
    }

    #[test]
    fn test_delete_property_retire_des_entries() {
        let repo = MockDbRepo::new();
        let prop = Property::new("Statut", PropertyType::Text);
        let prop_id = prop.id;
        let mut db = Database::new(title("DB"), vec![prop]);
        let mut values = HashMap::new();
        values.insert(prop_id, PropertyValue::Text("En cours".to_string()));
        db.entries.push(Entry::new(values));
        repo.save(&db).unwrap();

        delete_property(&db_uow(&repo), db.id, prop_id).unwrap();

        let db = repo.load(db.id).unwrap();
        assert!(db.properties.is_empty());
        assert!(!db.entries[0].values.contains_key(&prop_id));
    }

    #[test]
    fn test_delete_property_inexistante_erreur() {
        let repo = MockDbRepo::new();
        let db = Database::new(title("DB"), vec![]);
        repo.save(&db).unwrap();

        let res = delete_property(&db_uow(&repo), db.id, Uuid::new_v4());
        assert!(matches!(res, Err(PinkhaError::NotFound(_))));
    }
}
