use crate::application::database_repository::DatabaseRepository;
use crate::application::error::ChaqaqError;
use crate::domain::database::{Database, DatabaseMeta};
use std::fs;
use std::path::PathBuf;
use uuid::Uuid;

pub struct DatabaseStore {
    dir: PathBuf,
}

impl DatabaseStore {
    pub fn nouveau(dir: PathBuf) -> Result<Self, ChaqaqError> {
        fs::create_dir_all(&dir)?;
        Ok(Self { dir })
    }

    fn chemin(&self, id: Uuid) -> PathBuf {
        self.dir.join(format!("{id}.json"))
    }
}

impl DatabaseRepository for DatabaseStore {
    fn save(&self, db: &Database) -> Result<(), ChaqaqError> {
        let json = serde_json::to_string_pretty(db)?;
        fs::write(self.chemin(db.id), json)?;
        Ok(())
    }

    fn load(&self, id: Uuid) -> Result<Database, ChaqaqError> {
        let chemin = self.chemin(id);
        let content = fs::read_to_string(&chemin).map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                ChaqaqError::NotFound(id)
            } else {
                ChaqaqError::Io(e)
            }
        })?;
        let db = serde_json::from_str(&content)?;
        Ok(db)
    }

    fn list_meta(&self) -> Result<Vec<DatabaseMeta>, ChaqaqError> {
        let mut metas = vec![];
        for entry in fs::read_dir(&self.dir)? {
            let entry = entry?;
            if entry.path().extension().and_then(|e| e.to_str()) == Some("json") {
                let content = fs::read_to_string(entry.path())?;
                let db: Database = serde_json::from_str(&content)?;
                metas.push(db.meta());
            }
        }
        Ok(metas)
    }

    fn delete(&self, id: Uuid) -> Result<(), ChaqaqError> {
        let chemin = self.chemin(id);
        fs::remove_file(&chemin).map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                ChaqaqError::NotFound(id)
            } else {
                ChaqaqError::Io(e)
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

    fn store_temp() -> DatabaseStore {
        let dir = std::env::temp_dir().join(format!("chaqaq_db_test_{}", Uuid::new_v4()));
        DatabaseStore::nouveau(dir).unwrap()
    }

    fn title(s: &str) -> Vec<InlineText> {
        vec![InlineText {
            content: s.to_string(),
            styles: vec![],
        }]
    }

    #[test]
    fn test_save_puis_load() {
        let store = store_temp();
        let db = Database::new(title("Projets"), vec![]);
        store.save(&db).unwrap();
        let chargee = store.load(db.id).unwrap();
        assert_eq!(chargee.id, db.id);
        assert_eq!(chargee.title, db.title);
    }

    #[test]
    fn test_load_inexistant_retourne_non_trouve() {
        let store = store_temp();
        let id = Uuid::new_v4();
        assert!(matches!(store.load(id), Err(ChaqaqError::NotFound(_))));
    }

    #[test]
    fn test_list_meta_retourne_toutes_les_databases() {
        let store = store_temp();
        let db1 = Database::new(title("Projets"), vec![]);
        let db2 = Database::new(title("Tâches"), vec![]);
        store.save(&db1).unwrap();
        store.save(&db2).unwrap();
        let metas = store.list_meta().unwrap();
        assert_eq!(metas.len(), 2);
    }

    #[test]
    fn test_delete_supprime_la_database() {
        let store = store_temp();
        let db = Database::new(title("Temp"), vec![]);
        store.save(&db).unwrap();
        store.delete(db.id).unwrap();
        assert!(matches!(store.load(db.id), Err(ChaqaqError::NotFound(_))));
    }

    #[test]
    fn test_delete_inexistant_retourne_non_trouve() {
        let store = store_temp();
        let id = Uuid::new_v4();
        assert!(matches!(store.delete(id), Err(ChaqaqError::NotFound(_))));
    }

    #[test]
    fn test_save_ecrase_version_precedente() {
        let store = store_temp();
        let prop = Property::new("Statut", PropertyType::Text);
        let prop_id = prop.id;
        let mut db = Database::new(title("Test"), vec![prop]);
        store.save(&db).unwrap();

        let mut values = HashMap::new();
        values.insert(prop_id, PropertyValue::Text("En cours".to_string()));
        db.entries.push(Entry::new(values));
        store.save(&db).unwrap();

        let chargee = store.load(db.id).unwrap();
        assert_eq!(chargee.entries.len(), 1);
    }
}
