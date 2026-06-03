use crate::application::error::PinkhaError;
use crate::application::repository::DocumentRepository;
use crate::application::resilience::retry_with_backoff;
use crate::domain::document::{Document, DocumentMeta, InlineText};
use crate::infrastructure::migrations::apply_document_migrations;
use rusqlite::{Connection, params};
use std::sync::Mutex;
use uuid::Uuid;

/// SQLite-backed document store.
///
/// All write and read operations go through a [`Mutex`]-protected connection
/// so the store can be shared across threads. WAL mode is enabled at
/// construction time for better concurrent read performance. Deletes are
/// soft (a `deleted_at` timestamp is set rather than removing the row),
/// which prepares the data for future CRDT-based sync.
pub struct SqliteDocumentStore {
    conn: Mutex<Connection>,
}

impl SqliteDocumentStore {
    /// Opens (or creates) a SQLite database at `path`, enables WAL mode, and
    /// applies all pending schema migrations.
    pub fn new(path: &str) -> Result<Self, PinkhaError> {
        let mut conn = Connection::open(path).map_err(|e| PinkhaError::Db(e.to_string()))?;
        conn.execute_batch("PRAGMA journal_mode=WAL;")
            .map_err(|e| PinkhaError::Db(e.to_string()))?;
        apply_document_migrations(&mut conn)?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    /// Creates an in-memory store — useful for unit tests.
    pub fn in_memory() -> Result<Self, PinkhaError> {
        Self::new(":memory:")
    }
}

impl DocumentRepository for SqliteDocumentStore {
    fn save(&self, doc: &Document) -> Result<(), PinkhaError> {
        // Pre-compute outside the retry closure: no extra cost on retries.
        let data = serde_json::to_string(doc)?;
        let title_text: String = doc
            .title
            .iter()
            .map(|i| i.content.as_str())
            .collect::<Vec<_>>()
            .join("");
        let title_json = serde_json::to_string(&doc.title)?;
        let now = chrono::Utc::now().to_rfc3339();
        let id = doc.id.to_string();
        let cover = doc.cover.clone();

        let folder_id = doc.folder_id.map(|u| u.to_string());
        let parent_doc_id = doc.parent_doc_id.map(|u| u.to_string());
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            conn.execute(
                "INSERT INTO documents (id, title_text, title_json, cover, updated_at, created_at, folder_id, parent_doc_id, data)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?5, ?6, ?7, ?8)
                 ON CONFLICT(id) DO UPDATE SET
                    title_text    = excluded.title_text,
                    title_json    = excluded.title_json,
                    cover         = excluded.cover,
                    updated_at    = excluded.updated_at,
                    folder_id     = excluded.folder_id,
                    parent_doc_id = excluded.parent_doc_id,
                    data          = excluded.data,
                    deleted_at    = NULL",
                params![id, title_text, title_json, cover, now, folder_id, parent_doc_id, data],
            )
            .map_err(|e| PinkhaError::Db(e.to_string()))?;
            Ok(())
        })
    }

    fn load(&self, id: Uuid) -> Result<Document, PinkhaError> {
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let result = conn.query_row(
                "SELECT data FROM documents WHERE id = ?1 AND deleted_at IS NULL",
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

    fn list(&self) -> Result<Vec<DocumentMeta>, PinkhaError> {
        self.list_by_folder_inner(None, false)
    }

    fn move_to_folder(&self, doc_id: Uuid, folder_id: Option<Uuid>) -> Result<(), PinkhaError> {
        let now = chrono::Utc::now().to_rfc3339();
        let fid = folder_id.map(|u| u.to_string());
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let affected = conn
                .execute(
                    "UPDATE documents SET folder_id = ?1, updated_at = ?2
                     WHERE id = ?3 AND deleted_at IS NULL",
                    params![fid, now, doc_id.to_string()],
                )
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            if affected == 0 {
                return Err(PinkhaError::NotFound(doc_id));
            }
            Ok(())
        })
    }

    fn list_by_folder(&self, folder_id: Option<Uuid>) -> Result<Vec<DocumentMeta>, PinkhaError> {
        self.list_by_folder_inner(folder_id, true)
    }

    fn delete(&self, id: Uuid) -> Result<(), PinkhaError> {
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let affected = conn
                .execute(
                    "UPDATE documents SET deleted_at = ?1 WHERE id = ?2 AND deleted_at IS NULL",
                    params![chrono::Utc::now().to_rfc3339(), id.to_string()],
                )
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            if affected == 0 {
                return Err(PinkhaError::NotFound(id));
            }
            Ok(())
        })
    }

    fn list_deleted(&self) -> Result<Vec<DocumentMeta>, PinkhaError> {
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let mut stmt = conn
                .prepare(
                    "SELECT id, title_json, cover, updated_at, created_at, folder_id, parent_doc_id
                     FROM documents WHERE deleted_at IS NOT NULL
                     ORDER BY deleted_at DESC",
                )
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            let rows = stmt
                .query_map([], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, Option<String>>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, String>(4)?,
                        row.get::<_, Option<String>>(5)?,
                        row.get::<_, Option<String>>(6)?,
                    ))
                })
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            let mut metas = Vec::new();
            for row in rows {
                let (id_str, title_json, cover, updated_at, created_at, fid, pdid) =
                    row.map_err(|e| PinkhaError::Db(e.to_string()))?;
                let id = Uuid::parse_str(&id_str).map_err(|_| {
                    PinkhaError::InvalidOperation(format!("UUID invalide : {id_str}"))
                })?;
                let title: Vec<InlineText> = serde_json::from_str(&title_json)?;
                metas.push(DocumentMeta {
                    id,
                    title,
                    cover,
                    updated_at,
                    created_at,
                    folder_id: fid.and_then(|s| Uuid::parse_str(&s).ok()),
                    parent_doc_id: pdid.and_then(|s| Uuid::parse_str(&s).ok()),
                });
            }
            Ok(metas)
        })
    }

    fn restore(&self, id: Uuid) -> Result<(), PinkhaError> {
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let affected = conn
                .execute(
                    "UPDATE documents SET deleted_at = NULL, updated_at = ?1
                     WHERE id = ?2 AND deleted_at IS NOT NULL",
                    params![chrono::Utc::now().to_rfc3339(), id.to_string()],
                )
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            if affected == 0 {
                return Err(PinkhaError::NotFound(id));
            }
            Ok(())
        })
    }

    fn purge(&self, id: Uuid) -> Result<(), PinkhaError> {
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let affected = conn
                .execute(
                    "DELETE FROM documents WHERE id = ?1 AND deleted_at IS NOT NULL",
                    params![id.to_string()],
                )
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            if affected == 0 {
                return Err(PinkhaError::InvalidOperation(format!(
                    "document {id} must be soft-deleted before it can be purged"
                )));
            }
            Ok(())
        })
    }
}

impl SqliteDocumentStore {
    fn list_by_folder_inner(
        &self,
        folder_id: Option<Uuid>,
        filter: bool,
    ) -> Result<Vec<DocumentMeta>, PinkhaError> {
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let sql = if filter {
                if folder_id.is_some() {
                    "SELECT id, title_json, cover, updated_at, created_at, folder_id, parent_doc_id
                     FROM documents WHERE deleted_at IS NULL AND folder_id = ?1
                     ORDER BY updated_at DESC"
                } else {
                    "SELECT id, title_json, cover, updated_at, created_at, folder_id, parent_doc_id
                     FROM documents WHERE deleted_at IS NULL AND folder_id IS NULL
                     ORDER BY updated_at DESC"
                }
            } else {
                "SELECT id, title_json, cover, updated_at, created_at, folder_id, parent_doc_id
                 FROM documents WHERE deleted_at IS NULL
                 ORDER BY updated_at DESC"
            };
            let fid_str = folder_id.map(|u| u.to_string());
            let mut stmt = conn
                .prepare(sql)
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            let mapper = |row: &rusqlite::Row<'_>| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, Option<String>>(5)?,
                    row.get::<_, Option<String>>(6)?,
                ))
            };
            let rows = if filter && folder_id.is_some() {
                stmt.query_map(params![fid_str], mapper)
            } else {
                stmt.query_map([], mapper)
            }
            .map_err(|e| PinkhaError::Db(e.to_string()))?;
            let mut metas = Vec::new();
            for row in rows {
                let (id_str, title_json, cover, updated_at, created_at, fid, pdid) =
                    row.map_err(|e| PinkhaError::Db(e.to_string()))?;
                let id = Uuid::parse_str(&id_str).map_err(|_| {
                    PinkhaError::InvalidOperation(format!("UUID invalide : {id_str}"))
                })?;
                let title: Vec<InlineText> = serde_json::from_str(&title_json)?;
                metas.push(DocumentMeta {
                    id,
                    title,
                    cover,
                    updated_at,
                    created_at,
                    folder_id: fid.and_then(|s| Uuid::parse_str(&s).ok()),
                    parent_doc_id: pdid.and_then(|s| Uuid::parse_str(&s).ok()),
                });
            }
            Ok(metas)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::document::Document;

    fn store() -> SqliteDocumentStore {
        SqliteDocumentStore::in_memory().unwrap()
    }

    fn doc(title: &str) -> Document {
        Document::new(vec![InlineText {
            content: title.to_string(),
            styles: vec![],
        }])
    }

    #[test]
    fn test_save_puis_load() {
        let store = store();
        let d = doc("Test");
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
        let mut d = doc("Ancien");
        store.save(&d).unwrap();
        d.title = vec![InlineText {
            content: "Nouveau".to_string(),
            styles: vec![],
        }];
        store.save(&d).unwrap();
        let loaded = store.load(d.id).unwrap();
        assert_eq!(loaded.title[0].content, "Nouveau");
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
        store.save(&d).unwrap(); // second save
        let created_at_after = store.list().unwrap()[0].created_at.clone();
        assert_eq!(created_at_initial, created_at_after);
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
            InlineText {
                content: "content".to_string(),
                styles: vec![],
            },
        ]));
        store.save(&d).unwrap();
        let metas = store.list().unwrap();
        assert_eq!(metas[0].title[0].content, "Titre riche");
    }
}
