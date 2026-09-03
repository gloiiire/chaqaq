use crate::application::error::PinkhaError;
use crate::application::resilience::retry_with_backoff;
use crate::application::shelf_repository::ShelfRepository;
use crate::domain::shelf::{Shelf, ShelfMeta};
use crate::infrastructure::migrations::apply_migrations;
use rusqlite::{Connection, params};
use std::sync::Mutex;
use uuid::Uuid;

pub struct SqliteShelfStore {
    conn: Mutex<Connection>,
}

impl SqliteShelfStore {
    pub fn new(path: &str) -> Result<Self, PinkhaError> {
        let mut conn = Connection::open(path).map_err(|e| PinkhaError::Db(e.to_string()))?;
        conn.execute_batch("PRAGMA journal_mode=WAL;")
            .map_err(|e| PinkhaError::Db(e.to_string()))?;
        apply_migrations(&mut conn)?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    pub fn in_memory() -> Result<Self, PinkhaError> {
        Self::new(":memory:")
    }
}

impl ShelfRepository for SqliteShelfStore {
    fn create(&self, name: &str, parent_id: Option<Uuid>) -> Result<Shelf, PinkhaError> {
        let shelf = Shelf::new(name, parent_id);
        let id = shelf.id.to_string();
        let parent = shelf.parent_id.map(|u| u.to_string());
        let icon = shelf.icon.clone();
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            conn.execute(
                "INSERT INTO shelves (id, name, parent_id, created_at, updated_at, icon)
                 VALUES (?1, ?2, ?3, ?4, ?4, ?5)",
                params![id, shelf.name, parent, shelf.created_at, icon],
            )
            .map_err(|e| PinkhaError::Db(e.to_string()))?;
            Ok(())
        })?;
        Ok(shelf)
    }

    fn get(&self, id: Uuid) -> Result<Shelf, PinkhaError> {
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let result = conn.query_row(
                "SELECT id, name, parent_id, created_at, updated_at, icon, manual_order
                 FROM shelves WHERE id = ?1 AND deleted_at IS NULL",
                params![id.to_string()],
                |row| {
                    Ok(Shelf {
                        id,
                        name: row.get(1)?,
                        parent_id: row
                            .get::<_, Option<String>>(2)?
                            .and_then(|s| Uuid::parse_str(&s).ok()),
                        created_at: row.get(3)?,
                        updated_at: row.get(4)?,
                        icon: row.get::<_, Option<String>>(5)?,
                        manual_order: row.get::<_, Option<i32>>(6)?,
                    })
                },
            );
            match result {
                Ok(f) => Ok(f),
                Err(rusqlite::Error::QueryReturnedNoRows) => Err(PinkhaError::NotFound(id)),
                Err(e) => Err(PinkhaError::Db(e.to_string())),
            }
        })
    }

    fn list(&self) -> Result<Vec<ShelfMeta>, PinkhaError> {
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let mut stmt = conn
                .prepare(
                    "SELECT id, name, parent_id, created_at, updated_at, icon, manual_order
                     FROM shelves WHERE deleted_at IS NULL ORDER BY name",
                )
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            let rows = stmt
                .query_map([], |row| {
                    let id_str: String = row.get(0)?;
                    Ok((
                        id_str,
                        row.get::<_, String>(1)?,
                        row.get::<_, Option<String>>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, String>(4)?,
                        row.get::<_, Option<String>>(5)?,
                        row.get::<_, Option<i32>>(6)?,
                    ))
                })
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            let mut metas = Vec::new();
            for row in rows {
                let (id_str, name, parent_str, created_at, updated_at, icon, manual_order) =
                    row.map_err(|e| PinkhaError::Db(e.to_string()))?;
                let id = Uuid::parse_str(&id_str).map_err(|_| {
                    PinkhaError::InvalidOperation(format!("invalid UUID: {id_str}"))
                })?;
                metas.push(ShelfMeta {
                    id,
                    name,
                    parent_id: parent_str.and_then(|s| Uuid::parse_str(&s).ok()),
                    created_at,
                    updated_at,
                    icon,
                    manual_order,
                });
            }
            Ok(metas)
        })
    }

    fn rename(&self, id: Uuid, new_name: &str) -> Result<(), PinkhaError> {
        let now = chrono::Utc::now().to_rfc3339();
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let affected = conn
                .execute(
                    "UPDATE shelves SET name = ?1, updated_at = ?2
                     WHERE id = ?3 AND deleted_at IS NULL",
                    params![new_name, now, id.to_string()],
                )
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            if affected == 0 {
                return Err(PinkhaError::NotFound(id));
            }
            Ok(())
        })
    }

    /// Soft-deletes the shelf — and nothing else.
    ///
    /// Deliberately **non-destructive**: the `shelf_id` of the leaves it
    /// holds and the `parent_id` of its sub-shelves are left untouched, so
    /// `restore()` brings the whole subtree back exactly as it was. A shelf
    /// in Compost is advertised as recoverable; flattening its contents on
    /// the way in made that promise a lie (the association was gone for
    /// good, in the column *and* the blob).
    ///
    /// Visibility is computed instead of stored: a leaf whose shelf is not
    /// an *active* shelf reads as a root leaf (`list_by_shelf_inner`), and a
    /// shelf whose parent is not active reads as a root shelf
    /// (`list_child_shelves`). The destructive orphaning now happens in
    /// [`Self::purge`], where it is genuinely irreversible by definition.
    fn delete(&self, id: Uuid) -> Result<(), PinkhaError> {
        let now = chrono::Utc::now().to_rfc3339();
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let affected = conn
                .execute(
                    "UPDATE shelves SET deleted_at = ?1 WHERE id = ?2 AND deleted_at IS NULL",
                    params![now, id.to_string()],
                )
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            if affected == 0 {
                return Err(PinkhaError::NotFound(id));
            }
            Ok(())
        })
    }

    fn set_manual_order(&self, ordered_ids: &[Uuid]) -> Result<(), PinkhaError> {
        retry_with_backoff(|| {
            let mut conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let tx = conn
                .transaction()
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            for (idx, id) in ordered_ids.iter().enumerate() {
                tx.execute(
                    "UPDATE shelves SET manual_order = ?1
                       WHERE id = ?2 AND deleted_at IS NULL",
                    params![idx as i32, id.to_string()],
                )
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            }
            tx.commit().map_err(|e| PinkhaError::Db(e.to_string()))?;
            Ok(())
        })
    }

    fn move_shelf(&self, id: Uuid, new_parent_id: Option<Uuid>) -> Result<(), PinkhaError> {
        let now = chrono::Utc::now().to_rfc3339();
        let parent = new_parent_id.map(|u| u.to_string());
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let affected = conn
                .execute(
                    "UPDATE shelves SET parent_id = ?1, updated_at = ?2
                     WHERE id = ?3 AND deleted_at IS NULL",
                    params![parent, now, id.to_string()],
                )
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            if affected == 0 {
                return Err(PinkhaError::NotFound(id));
            }
            Ok(())
        })
    }

    fn list_deleted(&self) -> Result<Vec<ShelfMeta>, PinkhaError> {
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let mut stmt = conn
                .prepare(
                    "SELECT id, name, parent_id, created_at, updated_at, icon, manual_order
                     FROM shelves WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC",
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
                        row.get::<_, Option<i32>>(6)?,
                    ))
                })
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            let mut metas = Vec::new();
            for row in rows {
                let (id_str, name, parent_str, created_at, updated_at, icon, manual_order) =
                    row.map_err(|e| PinkhaError::Db(e.to_string()))?;
                let id = Uuid::parse_str(&id_str).map_err(|_| {
                    PinkhaError::InvalidOperation(format!("invalid UUID: {id_str}"))
                })?;
                metas.push(ShelfMeta {
                    id,
                    name,
                    parent_id: parent_str.and_then(|s| Uuid::parse_str(&s).ok()),
                    created_at,
                    updated_at,
                    icon,
                    manual_order,
                });
            }
            Ok(metas)
        })
    }

    fn update_icon(&self, id: Uuid, icon: Option<&str>) -> Result<(), PinkhaError> {
        let now = chrono::Utc::now().to_rfc3339();
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let affected = conn
                .execute(
                    "UPDATE shelves SET icon = ?1, updated_at = ?2
                     WHERE id = ?3 AND deleted_at IS NULL",
                    params![icon, now, id.to_string()],
                )
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            if affected == 0 {
                return Err(PinkhaError::NotFound(id));
            }
            Ok(())
        })
    }

    fn restore(&self, id: Uuid) -> Result<(), PinkhaError> {
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let affected = conn
                .execute(
                    "UPDATE shelves SET deleted_at = NULL, updated_at = ?1
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

    /// Permanently removes the shelf and cuts every reference to it.
    ///
    /// This is where the orphaning that [`Self::delete`] used to do now
    /// lives: the row is about to stop existing, so any leaf or sub-shelf
    /// still pointing at it must be re-homed or it would dangle forever.
    /// Leaves go to the library root (column **and** JSON blob, so a later
    /// `save()` can't resurrect the dead id), sub-shelves inherit the
    /// purged shelf's own parent.
    ///
    /// All of it runs in one transaction — a partial purge would leave
    /// leaves pointing at a shelf row that no longer exists.
    ///
    /// Trashed leaves are re-homed too (no `deleted_at` filter): the shelf
    /// is disappearing for good, so even a leaf sitting in Compost has to
    /// let go of it before it can ever be restored.
    fn purge(&self, id: Uuid) -> Result<(), PinkhaError> {
        retry_with_backoff(|| {
            let mut conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let tx = conn
                .transaction()
                .map_err(|e| PinkhaError::Db(e.to_string()))?;

            // Inherit the purged shelf's parent for its children.
            let parent: Option<String> = tx
                .query_row(
                    "SELECT parent_id FROM shelves WHERE id = ?1",
                    params![id.to_string()],
                    |row| row.get(0),
                )
                .unwrap_or(None);

            tx.execute(
                "UPDATE leaves
                    SET shelf_id = NULL,
                        data     = json_set(data, '$.shelf_id', json('null'))
                  WHERE shelf_id = ?1",
                params![id.to_string()],
            )
            .map_err(|e| PinkhaError::Db(e.to_string()))?;

            tx.execute(
                "UPDATE shelves SET parent_id = ?1 WHERE parent_id = ?2",
                params![parent, id.to_string()],
            )
            .map_err(|e| PinkhaError::Db(e.to_string()))?;

            let affected = tx
                .execute(
                    "DELETE FROM shelves WHERE id = ?1 AND deleted_at IS NOT NULL",
                    params![id.to_string()],
                )
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            if affected == 0 {
                return Err(PinkhaError::InvalidOperation(format!(
                    "shelf {id} must be soft-deleted before it can be purged"
                )));
            }
            tx.commit().map_err(|e| PinkhaError::Db(e.to_string()))?;
            Ok(())
        })
    }
}
