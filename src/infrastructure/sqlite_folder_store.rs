use crate::application::error::PinkhaError;
use crate::application::folder_repository::FolderRepository;
use crate::application::resilience::retry_with_backoff;
use crate::domain::folder::{Folder, FolderMeta};
use crate::infrastructure::migrations::apply_migrations;
use rusqlite::{Connection, params};
use std::sync::Mutex;
use uuid::Uuid;

pub struct SqliteFolderStore {
    conn: Mutex<Connection>,
}

impl SqliteFolderStore {
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

impl FolderRepository for SqliteFolderStore {
    fn create(&self, name: &str, parent_id: Option<Uuid>) -> Result<Folder, PinkhaError> {
        let folder = Folder::new(name, parent_id);
        let id = folder.id.to_string();
        let parent = folder.parent_id.map(|u| u.to_string());
        let icon = folder.icon.clone();
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            conn.execute(
                "INSERT INTO folders (id, name, parent_id, created_at, updated_at, icon)
                 VALUES (?1, ?2, ?3, ?4, ?4, ?5)",
                params![id, folder.name, parent, folder.created_at, icon],
            )
            .map_err(|e| PinkhaError::Db(e.to_string()))?;
            Ok(())
        })?;
        Ok(folder)
    }

    fn get(&self, id: Uuid) -> Result<Folder, PinkhaError> {
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let result = conn.query_row(
                "SELECT id, name, parent_id, created_at, updated_at, icon
                 FROM folders WHERE id = ?1 AND deleted_at IS NULL",
                params![id.to_string()],
                |row| {
                    Ok(Folder {
                        id,
                        name: row.get(1)?,
                        parent_id: row
                            .get::<_, Option<String>>(2)?
                            .and_then(|s| Uuid::parse_str(&s).ok()),
                        created_at: row.get(3)?,
                        updated_at: row.get(4)?,
                        icon: row.get::<_, Option<String>>(5)?,
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

    fn list(&self) -> Result<Vec<FolderMeta>, PinkhaError> {
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let mut stmt = conn
                .prepare(
                    "SELECT id, name, parent_id, created_at, updated_at, icon
                     FROM folders WHERE deleted_at IS NULL ORDER BY name",
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
                    ))
                })
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            let mut metas = Vec::new();
            for row in rows {
                let (id_str, name, parent_str, created_at, updated_at, icon) =
                    row.map_err(|e| PinkhaError::Db(e.to_string()))?;
                let id = Uuid::parse_str(&id_str).map_err(|_| {
                    PinkhaError::InvalidOperation(format!("invalid UUID: {id_str}"))
                })?;
                metas.push(FolderMeta {
                    id,
                    name,
                    parent_id: parent_str.and_then(|s| Uuid::parse_str(&s).ok()),
                    created_at,
                    updated_at,
                    icon,
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
                    "UPDATE folders SET name = ?1, updated_at = ?2
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

    fn delete(&self, id: Uuid) -> Result<(), PinkhaError> {
        let now = chrono::Utc::now().to_rfc3339();
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            // Move orphaned documents to root before deleting the folder.
            conn.execute(
                "UPDATE documents SET folder_id = NULL WHERE folder_id = ?1",
                params![id.to_string()],
            )
            .map_err(|e| PinkhaError::Db(e.to_string()))?;
            // Reparent child folders to the deleted folder's parent.
            let parent: Option<String> = conn
                .query_row(
                    "SELECT parent_id FROM folders WHERE id = ?1",
                    params![id.to_string()],
                    |row| row.get(0),
                )
                .unwrap_or(None);
            conn.execute(
                "UPDATE folders SET parent_id = ?1 WHERE parent_id = ?2 AND deleted_at IS NULL",
                params![parent, id.to_string()],
            )
            .map_err(|e| PinkhaError::Db(e.to_string()))?;
            let affected = conn
                .execute(
                    "UPDATE folders SET deleted_at = ?1 WHERE id = ?2 AND deleted_at IS NULL",
                    params![now, id.to_string()],
                )
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            if affected == 0 {
                return Err(PinkhaError::NotFound(id));
            }
            Ok(())
        })
    }

    fn move_folder(&self, id: Uuid, new_parent_id: Option<Uuid>) -> Result<(), PinkhaError> {
        let now = chrono::Utc::now().to_rfc3339();
        let parent = new_parent_id.map(|u| u.to_string());
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let affected = conn
                .execute(
                    "UPDATE folders SET parent_id = ?1, updated_at = ?2
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

    fn list_deleted(&self) -> Result<Vec<FolderMeta>, PinkhaError> {
        retry_with_backoff(|| {
            let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
            let mut stmt = conn
                .prepare(
                    "SELECT id, name, parent_id, created_at, updated_at, icon
                     FROM folders WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC",
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
                    ))
                })
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            let mut metas = Vec::new();
            for row in rows {
                let (id_str, name, parent_str, created_at, updated_at, icon) =
                    row.map_err(|e| PinkhaError::Db(e.to_string()))?;
                let id = Uuid::parse_str(&id_str).map_err(|_| {
                    PinkhaError::InvalidOperation(format!("invalid UUID: {id_str}"))
                })?;
                metas.push(FolderMeta {
                    id,
                    name,
                    parent_id: parent_str.and_then(|s| Uuid::parse_str(&s).ok()),
                    created_at,
                    updated_at,
                    icon,
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
                    "UPDATE folders SET icon = ?1, updated_at = ?2
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
                    "UPDATE folders SET deleted_at = NULL, updated_at = ?1
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
                    "DELETE FROM folders WHERE id = ?1 AND deleted_at IS NOT NULL",
                    params![id.to_string()],
                )
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
            if affected == 0 {
                return Err(PinkhaError::InvalidOperation(format!(
                    "folder {id} must be soft-deleted before it can be purged"
                )));
            }
            Ok(())
        })
    }
}
