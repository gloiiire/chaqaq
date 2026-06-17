use crate::application::error::PinkhaError;
use crate::application::repository::LeafRepository;
use crate::application::resilience::retry_with_backoff;
use crate::domain::leaf::{Leaf, LeafMeta, InlineText};
use crate::infrastructure::migrations::apply_leaf_migrations;
use rusqlite::{Connection, params};
use std::sync::Mutex;
use uuid::Uuid;

/// SQLite-backed leaf store.
///
/// All write and read operations go through a [`Mutex`]-protected connection
/// so the store can be shared across threads. WAL mode is enabled at
/// construction time for better concurrent read performance. Deletes are
/// soft (a `deleted_at` timestamp is set rather than removing the row),
/// which prepares the data for future CRDT-based sync.
pub struct SqliteLeafStore {
    conn: Mutex<Connection>,
}

impl SqliteLeafStore {
    /// Opens (or creates) a SQLite book at `path`, enables WAL mode, and
    /// applies all pending schema migrations.
    pub fn new(path: &str) -> Result<Self, PinkhaError> {
        let mut conn = Connection::open(path).map_err(|e| PinkhaError::Db(e.to_string()))?;
        conn.execute_batch("PRAGMA journal_mode=WAL;")
            .map_err(|e| PinkhaError::Db(e.to_string()))?;
        apply_leaf_migrations(&mut conn)?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    /// Creates an in-memory store — useful for unit tests.
    pub fn in_memory() -> Result<Self, PinkhaError> {
        Self::new(":memory:")
    }
}

impl LeafRepository for SqliteLeafStore {
    fn save(&self, doc: &Leaf) -> Result<(), PinkhaError> {
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
        // `created_at` on the row is set only at the very first INSERT
        // and never updated afterwards. Importers can pass through the
        // origin platform's creation timestamp via `doc.created_at`
        // (Notion's `created_time`, Bear's `ZCREATIONDATE`, Craft's
        // `creationDate`) so the imported doc keeps its real history.
        // Native docs leave it `None` and fall back to `now`.
        let created_at = doc.created_at.clone().unwrap_or_else(|| now.clone());
        let id = doc.id.to_string();
        let cover = doc.cover.clone();

        let shelf_id = doc.shelf_id.map(|u| u.to_string());
        let parent_leaf_id = doc.parent_leaf_id.map(|u| u.to_string());
        let icon = doc.icon.clone();
        // `published_at` defaults to the row's creation timestamp when the
        // caller hasn't overridden it ; that way fresh docs sort identically
        // under both `created` and `published`, and only the user-edit path
        // makes them diverge. The empty-string sentinel is resolved in SQL
        // (`CASE WHEN ?7 = ''`) because only the row knows its real `created_at`
        // — for a native doc `doc.created_at` is `None` and the Rust-side
        // fallback would be the *save* time, polluting resets with "now".
        let published_at = doc.published_at.clone();
        let pinned_at = doc.pinned_at.clone();
        let manual_order = doc.manual_order;
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            conn.execute(
                "INSERT INTO leaves (id, title_text, title_json, cover, updated_at, created_at, published_at, shelf_id, parent_leaf_id, icon, data, pinned_at, manual_order)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, CASE WHEN ?7 = '' THEN ?6 ELSE ?7 END, ?8, ?9, ?10, ?11, ?12, ?13)
                 ON CONFLICT(id) DO UPDATE SET
                    title_text    = excluded.title_text,
                    title_json    = excluded.title_json,
                    cover         = excluded.cover,
                    updated_at    = excluded.updated_at,
                    published_at  = CASE WHEN ?7 = '' THEN leaves.created_at ELSE ?7 END,
                    shelf_id     = excluded.shelf_id,
                    parent_leaf_id = excluded.parent_leaf_id,
                    icon          = excluded.icon,
                    data          = excluded.data,
                    pinned_at     = excluded.pinned_at,
                    manual_order  = excluded.manual_order,
                    deleted_at    = NULL",
                params![id, title_text, title_json, cover, now, created_at, published_at, shelf_id, parent_leaf_id, icon, data, pinned_at, manual_order],
            )
            .map_err(|e| PinkhaError::Db(e.to_string()))?;
            Ok(())
        })
    }

    /// Bulk-rewrites `manual_order` for a list of leaf ids in the
    /// passed order — first id gets index 0, second gets 1, etc.
    /// Used by the drag-and-drop reorder UI : the Swift side computes
    /// the new array, we persist it in one transaction.
    fn set_manual_order(&self, ordered_ids: &[Uuid]) -> Result<(), PinkhaError> {
        retry_with_backoff(|| {
            let mut conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let tx = conn
                .transaction()
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            for (idx, id) in ordered_ids.iter().enumerate() {
                tx.execute(
                    "UPDATE leaves
                        SET manual_order = ?1,
                            data         = json_set(data, '$.manual_order', ?1)
                      WHERE id = ?2 AND deleted_at IS NULL",
                    params![idx as i32, id.to_string()],
                )
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            }
            tx.commit().map_err(|e| PinkhaError::Db(e.to_string()))?;
            Ok(())
        })
    }

    fn set_pinned(&self, leaf_id: Uuid, pinned: bool) -> Result<(), PinkhaError> {
        let now = chrono::Utc::now().to_rfc3339();
        let pinned_at: Option<String> = if pinned { Some(now.clone()) } else { None };
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            // Update both the indexed column AND the JSON data blob's
            // own `pinned_at` field with `json_set` so the next `load()`
            // returns a Leaf whose `doc.pinned_at` matches reality.
            // Without that the JSON would diverge after pin/unpin until
            // the next full save, and the editor would render a stale
            // pin state.
            let affected = conn
                .execute(
                    "UPDATE leaves
                        SET pinned_at = ?1,
                            data      = json_set(data, '$.pinned_at',
                                CASE WHEN ?1 IS NULL
                                     THEN json('null')
                                     ELSE ?1 END),
                            updated_at = ?2
                      WHERE id = ?3 AND deleted_at IS NULL",
                    params![pinned_at, now, leaf_id.to_string()],
                )
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            if affected == 0 {
                return Err(PinkhaError::NotFound(leaf_id));
            }
            Ok(())
        })
    }

    fn load(&self, id: Uuid) -> Result<Leaf, PinkhaError> {
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let result = conn.query_row(
                "SELECT data FROM leaves WHERE id = ?1 AND deleted_at IS NULL",
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

    fn list(&self) -> Result<Vec<LeafMeta>, PinkhaError> {
        self.list_by_shelf_inner(None, false)
    }

    fn move_to_shelf(&self, leaf_id: Uuid, shelf_id: Option<Uuid>) -> Result<(), PinkhaError> {
        let now = chrono::Utc::now().to_rfc3339();
        let fid = shelf_id.map(|u| u.to_string());
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let affected = conn
                .execute(
                    "UPDATE leaves SET shelf_id = ?1, updated_at = ?2
                     WHERE id = ?3 AND deleted_at IS NULL",
                    params![fid, now, leaf_id.to_string()],
                )
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            if affected == 0 {
                return Err(PinkhaError::NotFound(leaf_id));
            }
            Ok(())
        })
    }

    fn list_by_shelf(&self, shelf_id: Option<Uuid>) -> Result<Vec<LeafMeta>, PinkhaError> {
        self.list_by_shelf_inner(shelf_id, true)
    }

    fn delete(&self, id: Uuid) -> Result<(), PinkhaError> {
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let affected = conn
                .execute(
                    "UPDATE leaves SET deleted_at = ?1 WHERE id = ?2 AND deleted_at IS NULL",
                    params![chrono::Utc::now().to_rfc3339(), id.to_string()],
                )
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            if affected == 0 {
                return Err(PinkhaError::NotFound(id));
            }
            Ok(())
        })
    }

    fn list_deleted(&self) -> Result<Vec<LeafMeta>, PinkhaError> {
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let mut stmt = conn
                .prepare(
                    "SELECT id, title_json, cover, updated_at, created_at, shelf_id, parent_leaf_id, icon, published_at, pinned_at, manual_order
                     FROM leaves WHERE deleted_at IS NOT NULL
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
                        row.get::<_, Option<String>>(7)?,
                        row.get::<_, String>(8)?,
                        row.get::<_, Option<String>>(9)?,
                        row.get::<_, Option<i32>>(10)?,
                    ))
                })
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            let mut metas = Vec::new();
            for row in rows {
                let (
                    id_str,
                    title_json,
                    cover,
                    updated_at,
                    created_at,
                    fid,
                    pdid,
                    icon,
                    published_at,
                    pinned_at,
                    manual_order,
                ) = row.map_err(|e| PinkhaError::Db(e.to_string()))?;
                let id = Uuid::parse_str(&id_str).map_err(|_| {
                    PinkhaError::InvalidOperation(format!("invalid UUID: {id_str}"))
                })?;
                let title: Vec<InlineText> = serde_json::from_str(&title_json)?;
                metas.push(LeafMeta {
                    id,
                    title,
                    cover,
                    icon,
                    updated_at,
                    created_at,
                    published_at,
                    shelf_id: fid.and_then(|s| Uuid::parse_str(&s).ok()),
                    parent_leaf_id: pdid.and_then(|s| Uuid::parse_str(&s).ok()),
                    pinned_at,
                    manual_order,
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
                    "UPDATE leaves SET deleted_at = NULL, updated_at = ?1
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
                    "DELETE FROM leaves WHERE id = ?1 AND deleted_at IS NOT NULL",
                    params![id.to_string()],
                )
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            if affected == 0 {
                return Err(PinkhaError::InvalidOperation(format!(
                    "leaf {id} must be soft-deleted before it can be purged"
                )));
            }
            Ok(())
        })
    }
}

impl SqliteLeafStore {
    fn list_by_shelf_inner(
        &self,
        shelf_id: Option<Uuid>,
        filter: bool,
    ) -> Result<Vec<LeafMeta>, PinkhaError> {
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let sql = if filter {
                if shelf_id.is_some() {
                    "SELECT id, title_json, cover, updated_at, created_at, shelf_id, parent_leaf_id, icon, published_at, pinned_at, manual_order
                     FROM leaves WHERE deleted_at IS NULL AND shelf_id = ?1
                     ORDER BY updated_at DESC"
                } else {
                    "SELECT id, title_json, cover, updated_at, created_at, shelf_id, parent_leaf_id, icon, published_at, pinned_at, manual_order
                     FROM leaves WHERE deleted_at IS NULL AND shelf_id IS NULL
                     ORDER BY updated_at DESC"
                }
            } else {
                "SELECT id, title_json, cover, updated_at, created_at, shelf_id, parent_leaf_id, icon, published_at, pinned_at, manual_order
                 FROM leaves WHERE deleted_at IS NULL
                 ORDER BY updated_at DESC"
            };
            let fid_str = shelf_id.map(|u| u.to_string());
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
                    row.get::<_, Option<String>>(7)?,
                    row.get::<_, String>(8)?,
                    row.get::<_, Option<String>>(9)?,
                    row.get::<_, Option<i32>>(10)?,
                ))
            };
            let rows = if filter && shelf_id.is_some() {
                stmt.query_map(params![fid_str], mapper)
            } else {
                stmt.query_map([], mapper)
            }
            .map_err(|e| PinkhaError::Db(e.to_string()))?;
            let mut metas = Vec::new();
            for row in rows {
                let (
                    id_str,
                    title_json,
                    cover,
                    updated_at,
                    created_at,
                    fid,
                    pdid,
                    icon,
                    published_at,
                    pinned_at,
                    manual_order,
                ) = row.map_err(|e| PinkhaError::Db(e.to_string()))?;
                let id = Uuid::parse_str(&id_str).map_err(|_| {
                    PinkhaError::InvalidOperation(format!("invalid UUID: {id_str}"))
                })?;
                let title: Vec<InlineText> = serde_json::from_str(&title_json)?;
                metas.push(LeafMeta {
                    id,
                    title,
                    cover,
                    icon,
                    updated_at,
                    created_at,
                    published_at,
                    shelf_id: fid.and_then(|s| Uuid::parse_str(&s).ok()),
                    parent_leaf_id: pdid.and_then(|s| Uuid::parse_str(&s).ok()),
                    pinned_at,
                    manual_order,
                });
            }
            Ok(metas)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::leaf::Leaf;

    fn store() -> SqliteLeafStore {
        SqliteLeafStore::in_memory().unwrap()
    }

    fn doc(title: &str) -> Leaf {
        Leaf::new(vec![InlineText {
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
    fn test_list_retourne_leaves_actifs() {
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
        d.add_block(crate::domain::leaf::BlockContent::Text(vec![
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
