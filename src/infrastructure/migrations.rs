use crate::application::error::PinkhaError;
use rusqlite::Connection;

/// Applies all versioned schema migrations to the given SQLite connection.
///
/// Creates the `documents` and `databases` tables if they do not exist,
/// then adds any columns introduced in later schema versions, and bumps
/// `PRAGMA user_version` to 4.
pub fn apply_migrations(conn: &mut Connection) -> Result<(), PinkhaError> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS folders (
            id          TEXT PRIMARY KEY,
            name        TEXT NOT NULL,
            parent_id   TEXT,
            created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            deleted_at  TEXT
        );

        CREATE TABLE IF NOT EXISTS documents (
            id          TEXT PRIMARY KEY,
            title_text  TEXT NOT NULL DEFAULT '',
            title_json  TEXT NOT NULL DEFAULT '[]',
            cover       TEXT,
            updated_at  TEXT NOT NULL,
            created_at  TEXT NOT NULL DEFAULT '',
            deleted_at  TEXT,
            data        TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS databases (
            id          TEXT PRIMARY KEY,
            title_text  TEXT NOT NULL DEFAULT '',
            title_json  TEXT NOT NULL DEFAULT '[]',
            updated_at  TEXT NOT NULL,
            created_at  TEXT NOT NULL DEFAULT '',
            deleted_at  TEXT,
            data        TEXT NOT NULL
        );",
    )
    .map_err(|e| PinkhaError::Db(e.to_string()))?;

    add_column_if_missing(conn, "documents", "created_at", "TEXT NOT NULL DEFAULT ''")?;
    add_column_if_missing(conn, "databases", "created_at", "TEXT NOT NULL DEFAULT ''")?;
    add_column_if_missing(conn, "documents", "folder_id", "TEXT")?;
    conn.pragma_update(None, "user_version", 5)
        .map_err(|e| PinkhaError::Db(e.to_string()))?;
    Ok(())
}

/// Applies document-table migrations. Delegates to [`apply_migrations`].
pub fn apply_document_migrations(conn: &mut Connection) -> Result<(), PinkhaError> {
    apply_migrations(conn)
}

/// Applies database-table migrations. Delegates to [`apply_migrations`].
pub fn apply_database_migrations(conn: &mut Connection) -> Result<(), PinkhaError> {
    apply_migrations(conn)
}

/// Adds a column to a table only if it does not already exist.
///
/// Uses `PRAGMA table_info` to inspect the current schema before issuing
/// `ALTER TABLE … ADD COLUMN`, making the migration idempotent.
fn add_column_if_missing(
    conn: &Connection,
    table: &str,
    column: &str,
    definition: &str,
) -> Result<(), PinkhaError> {
    let mut stmt = conn
        .prepare(&format!("PRAGMA table_info({table})"))
        .map_err(|e| PinkhaError::Db(e.to_string()))?;
    let columns = stmt
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|e| PinkhaError::Db(e.to_string()))?;

    for name in columns {
        if name.map_err(|e| PinkhaError::Db(e.to_string()))? == column {
            return Ok(());
        }
    }

    conn.execute_batch(&format!(
        "ALTER TABLE {table} ADD COLUMN {column} {definition};"
    ))
    .map_err(|e| PinkhaError::Db(e.to_string()))
}
