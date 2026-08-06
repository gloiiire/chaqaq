use crate::application::error::PinkhaError;
use crate::application::repository::LeafRepository;
use crate::application::resilience::retry_with_backoff;
use crate::domain::leaf::{InlineText, Leaf, LeafMeta};
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
        // PRO-62 : serialise the reader-settings bundle into its own
        // dedicated column so the JSON can be queried separately
        // (e.g. `WHERE json_extract(reader_settings_json, '$.font_scale') > 1`).
        // The same value lives inside the main `data` blob too —
        // that's the authoritative source, this column is a mirror.
        let reader_settings_json: Option<String> = doc
            .reader_settings
            .as_ref()
            .map(|s| serde_json::to_string(s).unwrap_or_default());
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
                "INSERT INTO leaves (id, title_text, title_json, cover, updated_at, created_at, published_at, shelf_id, parent_leaf_id, icon, data, pinned_at, manual_order, reader_settings_json)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, CASE WHEN ?7 = '' THEN ?6 ELSE ?7 END, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
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
                    reader_settings_json = excluded.reader_settings_json,
                    deleted_at    = NULL",
                params![id, title_text, title_json, cover, now, created_at, published_at, shelf_id, parent_leaf_id, icon, data, pinned_at, manual_order, reader_settings_json],
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

    /// Single-row projection over the indexed columns — same field
    /// sourcing as `list()`, so `load_meta(id)` and the matching entry
    /// from `list()` agree. Overrides the trait default, which would
    /// derive the meta from the JSON blob and return empty timestamps.
    fn load_meta(&self, id: Uuid) -> Result<LeafMeta, PinkhaError> {
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let result = conn.query_row(
                "SELECT title_json, cover, updated_at, created_at, shelf_id,
                        parent_leaf_id, icon, published_at, pinned_at, manual_order
                   FROM leaves WHERE id = ?1 AND deleted_at IS NULL",
                params![id.to_string()],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, Option<String>>(4)?,
                        row.get::<_, Option<String>>(5)?,
                        row.get::<_, Option<String>>(6)?,
                        row.get::<_, String>(7)?,
                        row.get::<_, Option<String>>(8)?,
                        row.get::<_, Option<i32>>(9)?,
                    ))
                },
            );
            let (
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
            ) = match result {
                Ok(row) => row,
                Err(rusqlite::Error::QueryReturnedNoRows) => {
                    return Err(PinkhaError::NotFound(id));
                }
                Err(e) => return Err(PinkhaError::Db(e.to_string())),
            };
            Ok(LeafMeta {
                id,
                title: serde_json::from_str(&title_json)?,
                cover,
                icon,
                updated_at,
                created_at,
                published_at,
                shelf_id: fid.and_then(|s| Uuid::parse_str(&s).ok()),
                parent_leaf_id: pdid.and_then(|s| Uuid::parse_str(&s).ok()),
                pinned_at,
                manual_order,
            })
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
            // Update both the indexed column AND the JSON data blob's own
            // `shelf_id` field via `json_set` — matches the pattern in
            // `set_pinned` and `set_manual_order`. Without the JSON mirror
            // the next `save()` (e.g. after a rename) would re-write the
            // column from a stale blob and lift the leaf back to the
            // library root, unshelving it silently.
            let affected = conn
                .execute(
                    "UPDATE leaves
                        SET shelf_id  = ?1,
                            data      = json_set(data, '$.shelf_id',
                                CASE WHEN ?1 IS NULL
                                     THEN json('null')
                                     ELSE ?1 END),
                            updated_at = ?2
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
                    // "Root" is computed, not stored. A leaf reads as a root
                    // leaf when it has no shelf *or* when its shelf is not an
                    // active one — i.e. the shelf sits in Compost. `delete()`
                    // on a shelf is deliberately non-destructive (it leaves
                    // `shelf_id` intact so `restore()` can bring the whole
                    // subtree back), so without this the leaves of a trashed
                    // shelf would belong to an invisible parent and vanish
                    // from every list.
                    "SELECT id, title_json, cover, updated_at, created_at, shelf_id, parent_leaf_id, icon, published_at, pinned_at, manual_order
                     FROM leaves
                     WHERE deleted_at IS NULL
                       AND (shelf_id IS NULL
                            OR shelf_id NOT IN (SELECT id FROM shelves WHERE deleted_at IS NULL))
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
        d.add_block(crate::domain::leaf::BlockContent::Text(vec![InlineText {
            content: "content".to_string(),
            styles: vec![],
        }]));
        store.save(&d).unwrap();
        let metas = store.list().unwrap();
        assert_eq!(metas[0].title[0].content, "Titre riche");
    }

    /// Regression: a leaf moved into a shelf must stay in that shelf after
    /// an unrelated `save()` (e.g. rename). The bug was that
    /// `move_to_shelf` only updated the `shelf_id` column, leaving the
    /// `data` blob's own `shelf_id` field stale — the next `save()` then
    /// rewrote the column from the stale blob and unshelved the leaf
    /// silently.
    #[test]
    fn test_move_to_shelf_survives_save_after_rename() {
        let store = store();
        let mut d = doc("À déplacer");
        let shelf_id = Uuid::new_v4();
        store.save(&d).unwrap();
        store.move_to_shelf(d.id, Some(shelf_id)).unwrap();
        // Rename simulates a subsequent `update_leaf_title`: load, mutate
        // title, save — the same flow that used to un-shelve the leaf.
        d = store.load(d.id).unwrap();
        d.title = vec![InlineText {
            content: "Renommée".to_string(),
            styles: vec![],
        }];
        store.save(&d).unwrap();
        let loaded = store.load(d.id).unwrap();
        assert_eq!(
            loaded.shelf_id,
            Some(shelf_id),
            "shelf_id survives save() after move_to_shelf"
        );
    }

    /// Regression: the two ways of reading one leaf's metadata must agree.
    /// `load_meta` used to derive from the JSON blob and returned empty
    /// `updated_at` / `created_at`, while `list()` returned the real column
    /// values for the same row.
    #[test]
    fn test_load_meta_agrees_with_list() {
        let store = store();
        let d = doc("Accord");
        store.save(&d).unwrap();
        store.set_pinned(d.id, true).unwrap();

        let meta = store.load_meta(d.id).unwrap();
        let listed = store
            .list()
            .unwrap()
            .into_iter()
            .find(|m| m.id == d.id)
            .expect("leaf in list");

        assert_eq!(meta.id, listed.id);
        assert_eq!(meta.title, listed.title);
        assert_eq!(meta.cover, listed.cover);
        assert_eq!(meta.icon, listed.icon);
        assert_eq!(meta.updated_at, listed.updated_at);
        assert_eq!(meta.created_at, listed.created_at);
        assert_eq!(meta.published_at, listed.published_at);
        assert_eq!(meta.shelf_id, listed.shelf_id);
        assert_eq!(meta.parent_leaf_id, listed.parent_leaf_id);
        assert_eq!(meta.pinned_at, listed.pinned_at);
        assert_eq!(meta.manual_order, listed.manual_order);

        assert!(!meta.updated_at.is_empty(), "timestamps are real");
        assert!(!meta.created_at.is_empty());
    }

    #[test]
    fn test_load_meta_missing_leaf_is_not_found() {
        let store = store();
        assert!(matches!(
            store.load_meta(Uuid::new_v4()),
            Err(PinkhaError::NotFound(_))
        ));
    }

    /// Regression: `set_pinned` writes an indexed column that also lives in
    /// the JSON blob. Same family as the `move_to_shelf` bug — if only the
    /// column were written, the next `save()` would restore the stale blob
    /// value and silently unpin the leaf.
    #[test]
    fn test_pin_survives_save_after_rename() {
        let store = store();
        let mut d = doc("À épingler");
        store.save(&d).unwrap();
        store.set_pinned(d.id, true).unwrap();

        d = store.load(d.id).unwrap();
        assert!(d.pinned_at.is_some(), "pinned_at reaches the blob");
        d.title = vec![InlineText {
            content: "Renommée".to_string(),
            styles: vec![],
        }];
        store.save(&d).unwrap();

        let loaded = store.load(d.id).unwrap();
        assert!(
            loaded.pinned_at.is_some(),
            "pin survives an unrelated save()"
        );
        let meta = store.list().unwrap();
        assert!(
            meta[0].pinned_at.is_some(),
            "column agrees with the blob after save()"
        );
    }

    /// Regression: same contract for `set_manual_order`, the other column
    /// mutator that mirrors into the blob.
    #[test]
    fn test_manual_order_survives_save_after_rename() {
        let store = store();
        let a = doc("A");
        let b = doc("B");
        store.save(&a).unwrap();
        store.save(&b).unwrap();
        store.set_manual_order(&[a.id, b.id]).unwrap();

        let mut reloaded_b = store.load(b.id).unwrap();
        assert_eq!(reloaded_b.manual_order, Some(1));
        reloaded_b.title = vec![InlineText {
            content: "B renommée".to_string(),
            styles: vec![],
        }];
        store.save(&reloaded_b).unwrap();

        assert_eq!(
            store.load(b.id).unwrap().manual_order,
            Some(1),
            "manual_order survives an unrelated save()"
        );
        let meta = store.list().unwrap();
        let b_meta = meta.iter().find(|m| m.id == b.id).unwrap();
        assert_eq!(
            b_meta.manual_order,
            Some(1),
            "column agrees with the blob after save()"
        );
    }

    /// Regression: moving a leaf out of a shelf (`shelf_id: None`) also
    /// syncs the JSON blob, so a subsequent `save()` doesn't resurrect the
    /// old shelf assignment.
    #[test]
    fn test_move_out_of_shelf_survives_save() {
        let store = store();
        let mut d = doc("Sortie de shelf");
        let shelf_id = Uuid::new_v4();
        store.save(&d).unwrap();
        store.move_to_shelf(d.id, Some(shelf_id)).unwrap();
        store.move_to_shelf(d.id, None).unwrap();
        d = store.load(d.id).unwrap();
        d.title = vec![InlineText {
            content: "Après retour racine".to_string(),
            styles: vec![],
        }];
        store.save(&d).unwrap();
        let loaded = store.load(d.id).unwrap();
        assert_eq!(loaded.shelf_id, None, "shelf_id stays None after save()");
    }
}
