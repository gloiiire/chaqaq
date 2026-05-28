use std::sync::Mutex;
use rusqlite::{Connection, params};
use uuid::Uuid;
use crate::application::error::ChaqaqError;
use crate::application::repository::DocumentRepository;
use crate::domain::document::{Document, DocumentMeta, InlineText};
use crate::infrastructure::migrations::appliquer_migrations_documents;

pub struct SqliteDocumentStore {
    conn: Mutex<Connection>,
}

impl SqliteDocumentStore {
    pub fn nouveau(chemin: &str) -> Result<Self, ChaqaqError> {
        let mut conn = Connection::open(chemin)
            .map_err(|e| ChaqaqError::Db(e.to_string()))?;
        conn.execute_batch("PRAGMA journal_mode=WAL;")
            .map_err(|e| ChaqaqError::Db(e.to_string()))?;
        appliquer_migrations_documents(&mut conn)?;
        Ok(Self { conn: Mutex::new(conn) })
    }

    pub fn en_memoire() -> Result<Self, ChaqaqError> {
        Self::nouveau(":memory:")
    }
}

impl DocumentRepository for SqliteDocumentStore {
    fn save(&self, doc: &Document) -> Result<(), ChaqaqError> {
        let conn = self.conn.lock().unwrap();
        let data = serde_json::to_string(doc)?;
        let title_text: String = doc.title.iter().map(|i| i.content.as_str()).collect::<Vec<_>>().join("");
        let title_json = serde_json::to_string(&doc.title)?;
        let now = chrono::Utc::now().to_rfc3339();
        conn.execute(
            "INSERT INTO documents (id, title_text, title_json, cover, updated_at, created_at, data)
             VALUES (?1, ?2, ?3, ?4, ?5, ?5, ?6)
             ON CONFLICT(id) DO UPDATE SET
                title_text = excluded.title_text,
                title_json = excluded.title_json,
                cover      = excluded.cover,
                updated_at = excluded.updated_at,
                data       = excluded.data,
                deleted_at = NULL",
            params![
                doc.id.to_string(),
                title_text,
                title_json,
                doc.cover,
                now,
                data,
            ],
        )
        .map_err(|e| ChaqaqError::Db(e.to_string()))?;
        Ok(())
    }

    fn load(&self, id: Uuid) -> Result<Document, ChaqaqError> {
        let conn = self.conn.lock().unwrap();
        let result = conn.query_row(
            "SELECT data FROM documents WHERE id = ?1 AND deleted_at IS NULL",
            params![id.to_string()],
            |row| row.get::<_, String>(0),
        );
        match result {
            Ok(data) => Ok(serde_json::from_str(&data)?),
            Err(rusqlite::Error::QueryReturnedNoRows) => Err(ChaqaqError::NonTrouve(id)),
            Err(e) => Err(ChaqaqError::Db(e.to_string())),
        }
    }

    fn list(&self) -> Result<Vec<DocumentMeta>, ChaqaqError> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare("SELECT id, title_json, cover, updated_at, created_at FROM documents WHERE deleted_at IS NULL")
            .map_err(|e| ChaqaqError::Db(e.to_string()))?;
        let mut metas = Vec::new();
        let rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                ))
            })
            .map_err(|e| ChaqaqError::Db(e.to_string()))?;
        for row in rows {
            let (id_str, title_json, cover, updated_at, created_at) = row.map_err(|e| ChaqaqError::Db(e.to_string()))?;
            let id = Uuid::parse_str(&id_str)
                .map_err(|_| ChaqaqError::OperationInvalide(format!("UUID invalide : {id_str}")))?;
            let title: Vec<InlineText> = serde_json::from_str(&title_json)?;
            metas.push(DocumentMeta { id, title, cover, updated_at, created_at });
        }
        Ok(metas)
    }

    fn delete(&self, id: Uuid) -> Result<(), ChaqaqError> {
        let conn = self.conn.lock().unwrap();
        let modifies = conn
            .execute(
                "UPDATE documents SET deleted_at = ?1 WHERE id = ?2 AND deleted_at IS NULL",
                params![chrono::Utc::now().to_rfc3339(), id.to_string()],
            )
            .map_err(|e| ChaqaqError::Db(e.to_string()))?;
        if modifies == 0 {
            return Err(ChaqaqError::NonTrouve(id));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::document::Document;

    fn store() -> SqliteDocumentStore {
        SqliteDocumentStore::en_memoire().unwrap()
    }

    fn doc(titre: &str) -> Document {
        Document::new(vec![InlineText { content: titre.to_string(), styles: vec![] }])
    }

    #[test]
    fn test_save_puis_load() {
        let store = store();
        let d = doc("Test");
        store.save(&d).unwrap();
        let charge = store.load(d.id).unwrap();
        assert_eq!(charge.id, d.id);
        assert_eq!(charge.title, d.title);
    }

    #[test]
    fn test_load_inexistant_retourne_non_trouve() {
        let store = store();
        assert!(matches!(store.load(Uuid::new_v4()), Err(ChaqaqError::NonTrouve(_))));
    }

    #[test]
    fn test_list_retourne_documents_actifs() {
        let store = store();
        store.save(&doc("Doc 1")).unwrap();
        store.save(&doc("Doc 2")).unwrap();
        assert_eq!(store.list().unwrap().len(), 2);
    }

    #[test]
    fn test_delete_soft_masque_du_listing_et_du_load() {
        let store = store();
        let d = doc("À supprimer");
        store.save(&d).unwrap();
        store.delete(d.id).unwrap();
        assert!(store.list().unwrap().is_empty());
        assert!(matches!(store.load(d.id), Err(ChaqaqError::NonTrouve(_))));
    }

    #[test]
    fn test_delete_inexistant_retourne_non_trouve() {
        let store = store();
        assert!(matches!(store.delete(Uuid::new_v4()), Err(ChaqaqError::NonTrouve(_))));
    }

    #[test]
    fn test_save_ecrase_version_precedente() {
        let store = store();
        let mut d = doc("Ancien");
        store.save(&d).unwrap();
        d.title = vec![InlineText { content: "Nouveau".to_string(), styles: vec![] }];
        store.save(&d).unwrap();
        let charge = store.load(d.id).unwrap();
        assert_eq!(charge.title[0].content, "Nouveau");
    }

    #[test]
    fn test_save_restaure_apres_suppression() {
        let store = store();
        let d = doc("Restauré");
        store.save(&d).unwrap();
        store.delete(d.id).unwrap();
        store.save(&d).unwrap();
        assert!(store.load(d.id).is_ok());
        assert_eq!(store.list().unwrap().len(), 1);
    }

    #[test]
    fn test_list_meta_contient_created_at() {
        let store = store();
        store.save(&doc("Test")).unwrap();
        let metas = store.list().unwrap();
        assert!(!metas[0].created_at.is_empty());
        assert!(metas[0].created_at.starts_with("20"));
    }

    #[test]
    fn test_created_at_ne_change_pas_apres_save() {
        let store = store();
        let d = doc("Test");
        store.save(&d).unwrap();
        let created_at_initial = store.list().unwrap()[0].created_at.clone();
        store.save(&d).unwrap(); // deuxième save
        let created_at_apres = store.list().unwrap()[0].created_at.clone();
        assert_eq!(created_at_initial, created_at_apres);
    }

    #[test]
    fn test_list_meta_contient_updated_at() {
        let store = store();
        store.save(&doc("Test")).unwrap();
        let metas = store.list().unwrap();
        assert!(!metas[0].updated_at.is_empty());
        assert!(metas[0].updated_at.starts_with("20")); // ISO 8601
    }

    #[test]
    fn test_list_meta_sans_deserialiser_les_blocs() {
        let store = store();
        let mut d = doc("Titre riche");
        d.add_block(crate::domain::document::BlockContent::Text(vec![
            InlineText { content: "contenu".to_string(), styles: vec![] }
        ]));
        store.save(&d).unwrap();
        let metas = store.list().unwrap();
        assert_eq!(metas[0].title[0].content, "Titre riche");
    }
}
