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
    // Parent document for Notion-style page-in-page hierarchy.
    // Indexed so `list_root_documents` and `list_child_documents` can scan
    // by this column without parsing every row's JSON `data` blob.
    add_column_if_missing(conn, "documents", "parent_doc_id", "TEXT")?;
    // Page icon (emoji or filename). Indexed so list_documents can return
    // it without parsing the JSON `data` blob — the home view uses this
    // to render the doc's chosen icon in rows and recent cards.
    add_column_if_missing(conn, "documents", "icon", "TEXT")?;
    // Backfill the icon column from the existing JSON `data` blob for
    // documents saved before the column existed. Without this, pre-7
    // documents would show the default fallback icon even though they
    // already carried an emoji inside their data.
    conn.execute(
        "UPDATE documents
            SET icon = json_extract(data, '$.icon')
          WHERE icon IS NULL
            AND json_extract(data, '$.icon') IS NOT NULL",
        [],
    )
    .map_err(|e| PinkhaError::Db(e.to_string()))?;
    // Folder icon (emoji). Folders share the same icon affordance as
    // documents in the Notion-style sidebar.
    add_column_if_missing(conn, "folders", "icon", "TEXT")?;
    // Database cover + icon. Mirrors the document treatment — indexed
    // columns so list_databases can return them without parsing each
    // row's JSON data blob, and a backfill from the data blob covers
    // databases written before the columns existed (None on rows that
    // never had a cover / icon in the first place).
    add_column_if_missing(conn, "databases", "cover", "TEXT")?;
    add_column_if_missing(conn, "databases", "icon", "TEXT")?;
    conn.execute(
        "UPDATE databases
            SET cover = json_extract(data, '$.cover')
          WHERE cover IS NULL
            AND json_extract(data, '$.cover') IS NOT NULL",
        [],
    )
    .map_err(|e| PinkhaError::Db(e.to_string()))?;
    conn.execute(
        "UPDATE databases
            SET icon = json_extract(data, '$.icon')
          WHERE icon IS NULL
            AND json_extract(data, '$.icon') IS NOT NULL",
        [],
    )
    .map_err(|e| PinkhaError::Db(e.to_string()))?;
    // User-editable publish timestamp on Document, parallel to the
    // one we added on Entry. Indexed so the home view's sort by
    // published date can skip the JSON blob. Backfilled from
    // `created_at` so pre-existing rows sort exactly like before
    // until the user overrides.
    add_column_if_missing(
        conn,
        "documents",
        "published_at",
        "TEXT NOT NULL DEFAULT ''",
    )?;
    conn.execute(
        "UPDATE documents
            SET published_at = created_at
          WHERE published_at = ''",
        [],
    )
    .map_err(|e| PinkhaError::Db(e.to_string()))?;
    conn.pragma_update(None, "user_version", 10)
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
