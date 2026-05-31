use crate::application::database_repository::DatabaseRepository;
use crate::application::error::PinkhaError;
use crate::application::resilience::retry_with_backoff;
use crate::domain::database::{Database, DatabaseMeta};
use crate::domain::document::InlineText;
use crate::infrastructure::migrations::apply_database_migrations;
use rusqlite::{Connection, params};
use std::sync::Mutex;
use uuid::Uuid;

pub struct SqliteDatabaseStore {
    conn: Mutex<Connection>,
}

impl SqliteDatabaseStore {
    pub fn new(path: &str) -> Result<Self, PinkhaError> {
        let mut conn = Connection::open(path).map_err(|e| PinkhaError::Db(e.to_string()))?;
        conn.execute_batch("PRAGMA journal_mode=WAL;")
            .map_err(|e| PinkhaError::Db(e.to_string()))?;
        apply_database_migrations(&mut conn)?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    pub fn in_memory() -> Result<Self, PinkhaError> {
        Self::new(":memory:")
    }
}

impl DatabaseRepository for SqliteDatabaseStore {
    fn save(&self, db: &Database) -> Result<(), PinkhaError> {
        // Pré-calcul hors retry : pas de coût en cas de relance.
        let data = serde_json::to_string(db)?;
        let title_text: String = db
            .title
            .iter()
            .map(|i| i.content.as_str())
            .collect::<Vec<_>>()
            .join("");
        let title_json = serde_json::to_string(&db.title)?;
        let now = chrono::Utc::now().to_rfc3339();
        let id = db.id.to_string();

        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            conn.execute(
                "INSERT INTO databases (id, title_text, title_json, updated_at, created_at, data)
                 VALUES (?1, ?2, ?3, ?4, ?4, ?5)
                 ON CONFLICT(id) DO UPDATE SET
                    title_text = excluded.title_text,
                    title_json = excluded.title_json,
                    updated_at = excluded.updated_at,
                    data       = excluded.data,
                    deleted_at = NULL",
                params![id, title_text, title_json, now, data],
            )
            .map_err(|e| PinkhaError::Db(e.to_string()))?;
            Ok(())
        })
    }

    fn load(&self, id: Uuid) -> Result<Database, PinkhaError> {
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let result = conn.query_row(
                "SELECT data FROM databases WHERE id = ?1 AND deleted_at IS NULL",
                params![id.to_string()],
                |row| row.get::<_, String>(0),
            );
            match result {
                Ok(data) => Ok(serde_json::from_str(&data)?),
                Err(rusqlite::Error::QueryReturnedNoRows) => Err(PinkhaError::NotFound(id)),
                Err(e) => Err(PinkhaError::Db(e.to_string())),
            }
        })
    }

    fn list_meta(&self) -> Result<Vec<DatabaseMeta>, PinkhaError> {
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let mut stmt = conn
                .prepare("SELECT id, title_json, updated_at, created_at FROM databases WHERE deleted_at IS NULL")
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            let rows = stmt
                .query_map([], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                    ))
                })
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            let mut metas = Vec::new();
            for row in rows {
                let (id_str, title_json, updated_at, created_at) =
                    row.map_err(|e| PinkhaError::Db(e.to_string()))?;
                let id = Uuid::parse_str(&id_str)
                    .map_err(|_| PinkhaError::InvalidOperation(format!("UUID invalide : {id_str}")))?;
                let title: Vec<InlineText> = serde_json::from_str(&title_json)?;
                metas.push(DatabaseMeta {
                    id,
                    title,
                    updated_at,
                    created_at,
                });
            }
            Ok(metas)
        })
    }

    fn delete(&self, id: Uuid) -> Result<(), PinkhaError> {
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let affected = conn
                .execute(
                    "UPDATE databases SET deleted_at = ?1 WHERE id = ?2 AND deleted_at IS NULL",
                    params![chrono::Utc::now().to_rfc3339(), id.to_string()],
                )
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            if affected == 0 {
                return Err(PinkhaError::NotFound(id));
            }
            Ok(())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::database::Database;

    fn store() -> SqliteDatabaseStore {
        SqliteDatabaseStore::in_memory().unwrap()
    }

    fn title(s: &str) -> Vec<InlineText> {
        vec![InlineText {
            content: s.to_string(),
            styles: vec![],
        }]
    }

    fn db(name: &str) -> Database {
        Database::new(title(name), vec![])
    }

    #[test]
    fn test_save_puis_load() {
        let store = store();
        let d = db("Projets");
        store.save(&d).unwrap();
        let loaded = store.load(d.id).unwrap();
        assert_eq!(loaded.id, d.id);
        assert_eq!(loaded.title, d.title);
    }

    #[test]
    fn test_load_inexistant_retourne_non_trouve() {
        let store = store();
        assert!(matches!(
            store.load(Uuid::new_v4()),
            Err(PinkhaError::NotFound(_))
        ));
    }

    #[test]
    fn test_list_meta_retourne_databases_actives() {
        let store = store();
        store.save(&db("Tâches")).unwrap();
        store.save(&db("Projets")).unwrap();
        assert_eq!(store.list_meta().unwrap().len(), 2);
    }

    #[test]
    fn test_delete_soft_masque_du_listing_et_du_load() {
        let store = store();
        let d = db("À supprimer");
        store.save(&d).unwrap();
        store.delete(d.id).unwrap();
        assert!(store.list_meta().unwrap().is_empty());
        assert!(matches!(store.load(d.id), Err(PinkhaError::NotFound(_))));
    }

    #[test]
    fn test_delete_inexistant_retourne_non_trouve() {
        let store = store();
        assert!(matches!(
            store.delete(Uuid::new_v4()),
            Err(PinkhaError::NotFound(_))
        ));
    }

    #[test]
    fn test_save_ecrase_version_precedente() {
        let store = store();
        let mut d = db("Ancien");
        store.save(&d).unwrap();
        d.title = title("Nouveau");
        store.save(&d).unwrap();
        let loaded = store.load(d.id).unwrap();
        assert_eq!(loaded.title[0].content, "Nouveau");
    }

    #[test]
    fn test_save_restaure_apres_suppression() {
        let store = store();
        let d = db("Restauré");
        store.save(&d).unwrap();
        store.delete(d.id).unwrap();
        store.save(&d).unwrap();
        assert!(store.load(d.id).is_ok());
        assert_eq!(store.list_meta().unwrap().len(), 1);
    }

    #[test]
    fn test_list_meta_contient_created_at() {
        let store = store();
        store.save(&db("Test")).unwrap();
        let metas = store.list_meta().unwrap();
        assert!(!metas[0].created_at.is_empty());
        assert!(metas[0].created_at.starts_with("20"));
    }

    #[test]
    fn test_created_at_ne_change_pas_apres_save() {
        let store = store();
        let d = db("Test");
        store.save(&d).unwrap();
        let created_at_initial = store.list_meta().unwrap()[0].created_at.clone();
        store.save(&d).unwrap();
        let created_at_after = store.list_meta().unwrap()[0].created_at.clone();
        assert_eq!(created_at_initial, created_at_after);
    }

    #[test]
    fn test_list_meta_contient_updated_at() {
        let store = store();
        store.save(&db("Test")).unwrap();
        let metas = store.list_meta().unwrap();
        assert!(!metas[0].updated_at.is_empty());
        assert!(metas[0].updated_at.starts_with("20")); // ISO 8601
    }

    #[test]
    fn test_list_meta_sans_deserialiser_les_entries() {
        let store = store();
        use crate::domain::database::{Entry, Property, PropertyType, PropertyValue};
        use std::collections::HashMap;
        let prop = Property::new("Nom", PropertyType::Text);
        let prop_id = prop.id;
        let mut d = Database::new(title("DB riche"), vec![prop]);
        let mut values = HashMap::new();
        values.insert(prop_id, PropertyValue::Text("entrée test".to_string()));
        d.entries.push(Entry::new(values));
        store.save(&d).unwrap();
        let metas = store.list_meta().unwrap();
        assert_eq!(metas[0].title[0].content, "DB riche");
    }
}
