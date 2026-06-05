use crate::application::database_repository::DatabaseRepository;
use crate::application::error::PinkhaError;
use crate::domain::database::{Database, DatabaseMeta};
use std::fs;
use std::path::PathBuf;
use uuid::Uuid;

/// File-system database store that persists each [`Database`] as a
/// pretty-printed JSON file named `<uuid>.json` inside a directory.
///
/// Kept alongside the SQLite store for tests and prototyping. Production code
/// should prefer [`SqliteDatabaseStore`].
pub struct DatabaseStore {
    dir: PathBuf,
}

impl DatabaseStore {
    /// Creates a new store rooted at `dir`, creating the directory if needed.
    pub fn new(dir: PathBuf) -> Result<Self, PinkhaError> {
        fs::create_dir_all(&dir)?;
        Ok(Self { dir })
    }

    /// Returns the expected file path for a database identified by `id`.
    fn path(&self, id: Uuid) -> PathBuf {
        self.dir.join(format!("{id}.json"))
    }
}

impl DatabaseRepository for DatabaseStore {
    fn save(&self, db: &Database) -> Result<(), PinkhaError> {
        let json = serde_json::to_string_pretty(db)?;
        // Atomic write: write to a .tmp file then rename — the store remains
        // consistent if the process dies mid-write.
        let target = self.path(db.id);
        let tmp = self.dir.join(format!(".{}.json.tmp", db.id));
        fs::write(&tmp, json)?;
        fs::rename(&tmp, &target)?;
        Ok(())
    }

    fn load(&self, id: Uuid) -> Result<Database, PinkhaError> {
        let p = self.path(id);
        let content = fs::read_to_string(&p).map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                PinkhaError::NotFound(id)
            } else {
                PinkhaError::Io(e)
            }
        })?;
        let db = serde_json::from_str(&content)?;
        Ok(db)
    }

    fn list_meta(&self) -> Result<Vec<DatabaseMeta>, PinkhaError> {
        // Tolerate corrupted files: skip them rather than failing the whole listing.
        let mut metas = Vec::new();
        for entry in fs::read_dir(&self.dir)? {
            let p = entry?.path();
            if p.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            if let Ok(content) = fs::read_to_string(&p)
                && let Ok(db) = serde_json::from_str::<Database>(&content)
            {
                metas.push(db.meta());
            }
        }
        Ok(metas)
    }

    fn delete(&self, id: Uuid) -> Result<(), PinkhaError> {
        let p = self.path(id);
        fs::remove_file(&p).map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                PinkhaError::NotFound(id)
            } else {
                PinkhaError::Io(e)
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::database::{Entry, Property, PropertyType, PropertyValue};
    use crate::domain::document::InlineText;
    use std::collections::HashMap;

    fn temp_store() -> DatabaseStore {
        let dir = std::env::temp_dir().join(format!("pinkha_db_test_{}", Uuid::new_v4()));
        DatabaseStore::new(dir).unwrap()
    }

    fn title(s: &str) -> Vec<InlineText> {
        vec![InlineText {
            content: s.to_string(),
            styles: vec![],
        }]
    }

    #[test]
    fn test_save_puis_load() {
        let store = temp_store();
        let db = Database::new(title("Projets"), vec![]);
        store.save(&db).unwrap();
        let loaded = store.load(db.id).unwrap();
        assert_eq!(loaded.id, db.id);
        assert_eq!(loaded.title, db.title);
    }

    #[test]
    fn test_load_inexistant_retourne_non_trouve() {
        let store = temp_store();
        let id = Uuid::new_v4();
        assert!(matches!(store.load(id), Err(PinkhaError::NotFound(_))));
    }

    #[test]
    fn test_list_meta_retourne_toutes_les_databases() {
        let store = temp_store();
        let db1 = Database::new(title("Projets"), vec![]);
        let db2 = Database::new(title("Tâches"), vec![]);
        store.save(&db1).unwrap();
        store.save(&db2).unwrap();
        let metas = store.list_meta().unwrap();
        assert_eq!(metas.len(), 2);
    }

    #[test]
    fn test_delete_supprime_la_database() {
        let store = temp_store();
        let db = Database::new(title("Temp"), vec![]);
        store.save(&db).unwrap();
        store.delete(db.id).unwrap();
        assert!(matches!(store.load(db.id), Err(PinkhaError::NotFound(_))));
    }

    #[test]
    fn test_delete_inexistant_retourne_non_trouve() {
        let store = temp_store();
        let id = Uuid::new_v4();
        assert!(matches!(store.delete(id), Err(PinkhaError::NotFound(_))));
    }

    #[test]
    fn test_save_ecrase_version_precedente() {
        let store = temp_store();
        let prop = Property::new("Statut", PropertyType::Text);
        let prop_id = prop.id;
        let mut db = Database::new(title("Test"), vec![prop]);
        store.save(&db).unwrap();

        let mut values = HashMap::new();
        values.insert(prop_id, PropertyValue::Text("En cours".to_string()));
        db.entries.push(Entry::new(values));
        store.save(&db).unwrap();

        let loaded = store.load(db.id).unwrap();
        assert_eq!(loaded.entries.len(), 1);
    }
}
