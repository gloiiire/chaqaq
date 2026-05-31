use crate::application::error::PinkhaError;
use rusqlite::Connection;

pub fn apply_migrations(conn: &mut Connection) -> Result<(), PinkhaError> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS documents (
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
    conn.pragma_update(None, "user_version", 4)
        .map_err(|e| PinkhaError::Db(e.to_string()))?;
    Ok(())
}

pub fn apply_document_migrations(conn: &mut Connection) -> Result<(), PinkhaError> {
    apply_migrations(conn)
}

pub fn apply_database_migrations(conn: &mut Connection) -> Result<(), PinkhaError> {
    apply_migrations(conn)
}

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
