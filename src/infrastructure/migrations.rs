use crate::application::error::PinkhaError;
use rusqlite::Connection;

/// Applies all versioned schema migrations to the given SQLite connection.
///
/// Creates the `leaves` and `books` tables if they do not exist,
/// then adds any columns introduced in later schema versions, and bumps
/// `PRAGMA user_version` to 4.
pub fn apply_migrations(conn: &mut Connection) -> Result<(), PinkhaError> {
    // Pre-rename legacy tables and columns so existing user databases
    // survive the Pinkha v0.2 vocabulary migration (documents → leaves,
    // databases → books, folders → shelves, folder_id → shelf_id,
    // parent_doc_id → parent_leaf_id). Idempotent — skips when the
    // legacy artefacts are already gone or when the new ones already
    // exist. Must run before the CREATE TABLE IF NOT EXISTS below,
    // otherwise SQLite would create empty `leaves`/`books`/`shelves`
    // alongside the still-populated legacy tables.
    rename_legacy_schema(conn)?;

    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS shelves (
            id          TEXT PRIMARY KEY,
            name        TEXT NOT NULL,
            parent_id   TEXT,
            created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            deleted_at  TEXT
        );

        CREATE TABLE IF NOT EXISTS leaves (
            id          TEXT PRIMARY KEY,
            title_text  TEXT NOT NULL DEFAULT '',
            title_json  TEXT NOT NULL DEFAULT '[]',
            cover       TEXT,
            updated_at  TEXT NOT NULL,
            created_at  TEXT NOT NULL DEFAULT '',
            deleted_at  TEXT,
            data        TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS books (
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

    add_column_if_missing(conn, "leaves", "created_at", "TEXT NOT NULL DEFAULT ''")?;
    add_column_if_missing(conn, "books", "created_at", "TEXT NOT NULL DEFAULT ''")?;
    add_column_if_missing(conn, "leaves", "shelf_id", "TEXT")?;
    // Parent leaf for Notion-style page-in-page hierarchy.
    // Indexed so `list_root_leaves` and `list_child_leaves` can scan
    // by this column without parsing every row's JSON `data` blob.
    add_column_if_missing(conn, "leaves", "parent_leaf_id", "TEXT")?;
    // Page icon (emoji or filename). Indexed so list_leaves can return
    // it without parsing the JSON `data` blob — the home view uses this
    // to render the doc's chosen icon in rows and recent cards.
    add_column_if_missing(conn, "leaves", "icon", "TEXT")?;
    // Backfill the icon column from the existing JSON `data` blob for
    // leaves saved before the column existed. Without this, pre-7
    // leaves would show the default fallback icon even though they
    // already carried an emoji inside their data.
    conn.execute(
        "UPDATE leaves
            SET icon = json_extract(data, '$.icon')
          WHERE icon IS NULL
            AND json_extract(data, '$.icon') IS NOT NULL",
        [],
    )
    .map_err(|e| PinkhaError::Db(e.to_string()))?;
    // Shelf icon (emoji). Shelves share the same icon affordance as
    // leaves in the Notion-style sidebar.
    add_column_if_missing(conn, "shelves", "icon", "TEXT")?;
    // Book cover + icon. Mirrors the leaf treatment — indexed
    // columns so list_books can return them without parsing each
    // row's JSON data blob, and a backfill from the data blob covers
    // books written before the columns existed (None on rows that
    // never had a cover / icon in the first place).
    add_column_if_missing(conn, "books", "cover", "TEXT")?;
    add_column_if_missing(conn, "books", "icon", "TEXT")?;
    conn.execute(
        "UPDATE books
            SET cover = json_extract(data, '$.cover')
          WHERE cover IS NULL
            AND json_extract(data, '$.cover') IS NOT NULL",
        [],
    )
    .map_err(|e| PinkhaError::Db(e.to_string()))?;
    conn.execute(
        "UPDATE books
            SET icon = json_extract(data, '$.icon')
          WHERE icon IS NULL
            AND json_extract(data, '$.icon') IS NOT NULL",
        [],
    )
    .map_err(|e| PinkhaError::Db(e.to_string()))?;
    // User-editable publish timestamp on Leaf, parallel to the
    // one we added on Entry. Indexed so the home view's sort by
    // published date can skip the JSON blob. Backfilled from
    // `created_at` so pre-existing rows sort exactly like before
    // until the user overrides.
    add_column_if_missing(
        conn,
        "leaves",
        "published_at",
        "TEXT NOT NULL DEFAULT ''",
    )?;
    conn.execute(
        "UPDATE leaves
            SET published_at = created_at
          WHERE published_at = ''",
        [],
    )
    .map_err(|e| PinkhaError::Db(e.to_string()))?;
    conn.pragma_update(None, "user_version", 10)
        .map_err(|e| PinkhaError::Db(e.to_string()))?;
    Ok(())
}

/// Applies leaf-table migrations. Delegates to [`apply_migrations`].
pub fn apply_leaf_migrations(conn: &mut Connection) -> Result<(), PinkhaError> {
    apply_migrations(conn)
}

/// Applies book-table migrations. Delegates to [`apply_migrations`].
pub fn apply_book_migrations(conn: &mut Connection) -> Result<(), PinkhaError> {
    apply_migrations(conn)
}

/// Renames legacy Document/Database/Folder tables and their columns
/// to the new Leaf/Book/Shelf vocabulary. Idempotent — silently skips
/// each rename if the source table/column is already gone (post-
/// migration) or the destination already exists (would conflict).
///
/// Order matters: we rename tables first, then columns, because
/// SQLite's `ALTER TABLE RENAME COLUMN` operates on the current name
/// of the table. Doing columns after the table-rename means the
/// column lookups see `leaves` not `documents`.
fn rename_legacy_schema(conn: &Connection) -> Result<(), PinkhaError> {
    fn table_exists(conn: &Connection, name: &str) -> Result<bool, PinkhaError> {
        let count: i32 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?",
                [name],
                |r| r.get(0),
            )
            .map_err(|e| PinkhaError::Db(e.to_string()))?;
        Ok(count > 0)
    }

    fn column_exists(conn: &Connection, table: &str, column: &str) -> Result<bool, PinkhaError> {
        let mut stmt = conn
            .prepare(&format!("PRAGMA table_info({table})"))
            .map_err(|e| PinkhaError::Db(e.to_string()))?;
        let rows = stmt
            .query_map([], |row| row.get::<_, String>(1))
            .map_err(|e| PinkhaError::Db(e.to_string()))?;
        for r in rows {
            let name = r.map_err(|e| PinkhaError::Db(e.to_string()))?;
            if name == column {
                return Ok(true);
            }
        }
        Ok(false)
    }

    // Tables.
    for (old, new) in [
        ("documents", "leaves"),
        ("databases", "books"),
        ("folders", "shelves"),
    ] {
        if table_exists(conn, old)? && !table_exists(conn, new)? {
            conn.execute_batch(&format!("ALTER TABLE {old} RENAME TO {new};"))
                .map_err(|e| PinkhaError::Db(e.to_string()))?;
        }
    }

    // Columns. Each tuple = (table, old_column, new_column).
    for (table, old_col, new_col) in [
        ("leaves", "folder_id", "shelf_id"),
        ("leaves", "parent_doc_id", "parent_leaf_id"),
    ] {
        if table_exists(conn, table)?
            && column_exists(conn, table, old_col)?
            && !column_exists(conn, table, new_col)?
        {
            conn.execute_batch(&format!(
                "ALTER TABLE {table} RENAME COLUMN {old_col} TO {new_col};"
            ))
            .map_err(|e| PinkhaError::Db(e.to_string()))?;
        }
    }

    Ok(())
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
