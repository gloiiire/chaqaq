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
    // Parent leaf for Notion-style page-in-page hierarchy. Denormalized out
    // of the JSON blob so `list_root_leaves` / `list_child_leaves` can
    // filter on it without parsing every row. Backed by
    // `idx_leaves_parent` (created at the end of this function).
    add_column_if_missing(conn, "leaves", "parent_leaf_id", "TEXT")?;
    // Page icon (emoji or filename). Denormalized so list_leaves can return
    // it without parsing the JSON `data` blob — the home view uses this
    // to render the doc's chosen icon in rows and recent cards. Never
    // filtered or sorted on, so intentionally not indexed.
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
    // Book cover + icon. Mirrors the leaf treatment — denormalized
    // columns so list_books can return them without parsing each
    // row's JSON data blob, and a backfill from the data blob covers
    // books written before the columns existed (None on rows that
    // never had a cover / icon in the first place). Projected, never
    // filtered on, so no index.
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
    // User-editable publish timestamp on Leaf, parallel to the one we
    // added on Entry. Denormalized so the home view's sort by published
    // date can skip the JSON blob. Backfilled from `created_at` so
    // pre-existing rows sort exactly like before until the user
    // overrides. (Sorting on it happens Swift-side today, so there is no
    // index — add one if it ever moves into SQL.)
    add_column_if_missing(conn, "leaves", "published_at", "TEXT NOT NULL DEFAULT ''")?;
    conn.execute(
        "UPDATE leaves
            SET published_at = created_at
          WHERE published_at = ''",
        [],
    )
    .map_err(|e| PinkhaError::Db(e.to_string()))?;
    // Pinned-at timestamp. `NULL` = not pinned. When set, the home view
    // surfaces the leaf in a dedicated PINNED section above SHELVES,
    // sorted by pinned_at desc so most recent pins appear first. Nullable
    // because the natural absence is "not pinned" — empty string would
    // require a sentinel branch every read.
    add_column_if_missing(conn, "leaves", "pinned_at", "TEXT")?;
    // Manual sort index for drag-and-drop reorder. NULL = follow the
    // section's natural order (creation/update date or `pinned_at`).
    // Integer column so we can scan an `ORDER BY manual_order` without
    // parsing the JSON blob.
    add_column_if_missing(conn, "leaves", "manual_order", "INTEGER")?;
    // Manual sort index for shelves — parallel to `leaves.manual_order`.
    // Powers the drag-and-drop reorder UI in the SHELVES section.
    add_column_if_missing(conn, "shelves", "manual_order", "INTEGER")?;
    // Rewrite the legacy `pinkha://doc/{uuid}` internal-link scheme to
    // the new `pinkha://leaf/{uuid}` after the page → leaf nomenclature
    // refactor. Idempotent — `REPLACE` is a no-op when the source
    // substring is absent. Touches the JSON blob in `data` so previously
    // imported leaves whose blocks reference each other keep working
    // after the rename.
    conn.execute(
        "UPDATE leaves
            SET data = REPLACE(data, 'pinkha://doc/', 'pinkha://leaf/')
          WHERE data LIKE '%pinkha://doc/%'",
        [],
    )
    .map_err(|e| PinkhaError::Db(e.to_string()))?;
    // Same rewrite on books (some block payloads — code/quote/text —
    // may carry inline links that mention a leaf).
    conn.execute(
        "UPDATE books
            SET data = REPLACE(data, 'pinkha://doc/', 'pinkha://leaf/')
          WHERE data LIKE '%pinkha://doc/%'",
        [],
    )
    .map_err(|e| PinkhaError::Db(e.to_string()))?;
    // Rewrite the legacy `BlockContent::Page { id }` variant tag to the
    // new `Leaf { id }` discriminant. Serde uses `"Page"` as the JSON
    // key for the variant in externally-tagged enums (the default).
    // Match a quoted `"Page":` to avoid touching arbitrary text that
    // happens to contain the word "Page" — we control how the value is
    // serialized, so this prefix is stable.
    conn.execute(
        "UPDATE leaves
            SET data = REPLACE(data, '\"Page\":', '\"Leaf\":')
          WHERE data LIKE '%\"Page\":%'",
        [],
    )
    .map_err(|e| PinkhaError::Db(e.to_string()))?;
    // Heal shelf_id divergence between the indexed column and the JSON
    // `data` blob. Pre-migration `move_to_shelf` only updated the column,
    // leaving the blob stale. Subsequent `save()` calls (e.g. rename)
    // then re-wrote the column from the stale blob and silently unshelved
    // the leaf. Fix in code (`json_set` in `move_to_shelf`), heal here.
    // Only touches rows where the blob's `shelf_id` differs from the
    // column — no-op for consistent rows.
    //
    // Deliberately NOT filtered on `deleted_at IS NULL`: the reconciliation
    // is column-authoritative and just as valid for trashed rows. Skipping
    // them would leave a leaf that was in Compost at upgrade time still
    // divergent, and `restore()` only clears `deleted_at` — so the first
    // `save()` after restoring would re-trigger the very bug this heals.
    conn.execute(
        "UPDATE leaves
            SET data = json_set(data, '$.shelf_id',
                CASE WHEN shelf_id IS NULL
                     THEN json('null')
                     ELSE shelf_id END)
          WHERE (shelf_id IS NULL AND json_extract(data, '$.shelf_id') IS NOT NULL)
             OR (shelf_id IS NOT NULL AND json_extract(data, '$.shelf_id') IS NOT shelf_id)",
        [],
    )
    .map_err(|e| PinkhaError::Db(e.to_string()))?;

    // ── Indexes ──────────────────────────────────────────────────────────
    //
    // Until now the only index in the database was the implicit
    // `PRIMARY KEY(id)` on each table — so every list, every shelf lookup
    // and every soft-delete filter was a full table scan followed by an
    // unindexed sort. On an imported library (2500+ leaves) that cost is
    // paid several times per screen refresh.
    //
    // Shapes are chosen to match the queries actually issued by the stores:
    //
    //  - `(deleted_at, updated_at DESC)` serves every listing, which is
    //    invariably `WHERE deleted_at IS NULL ORDER BY updated_at DESC` —
    //    one index covers both the filter and the sort, so SQLite can skip
    //    the sort entirely.
    //  - The `shelf_id` / `parent_leaf_id` indexes are *partial*
    //    (`WHERE … IS NOT NULL`): most leaves sit at the library root with
    //    both columns NULL, and indexing those rows would bloat the index
    //    with entries no query ever probes.
    //  - `pinned_at` likewise — pinned leaves are a handful out of thousands.
    //
    // `IF NOT EXISTS` keeps this idempotent, like the rest of this function.
    conn.execute_batch(
        "CREATE INDEX IF NOT EXISTS idx_leaves_active_updated
             ON leaves(deleted_at, updated_at DESC);
         CREATE INDEX IF NOT EXISTS idx_leaves_shelf
             ON leaves(shelf_id) WHERE shelf_id IS NOT NULL;
         CREATE INDEX IF NOT EXISTS idx_leaves_parent
             ON leaves(parent_leaf_id) WHERE parent_leaf_id IS NOT NULL;
         CREATE INDEX IF NOT EXISTS idx_leaves_pinned
             ON leaves(pinned_at) WHERE pinned_at IS NOT NULL;

         CREATE INDEX IF NOT EXISTS idx_books_active_updated
             ON books(deleted_at, updated_at DESC);

         CREATE INDEX IF NOT EXISTS idx_shelves_active
             ON shelves(deleted_at);
         CREATE INDEX IF NOT EXISTS idx_shelves_parent
             ON shelves(parent_id) WHERE parent_id IS NOT NULL;",
    )
    .map_err(|e| PinkhaError::Db(e.to_string()))?;

    conn.pragma_update(None, "user_version", 16)
        .map_err(|e| PinkhaError::Db(e.to_string()))?;

    // ── v15 (PRO-62) : `Leaf.reader_settings` JSON bundle ────────────────
    //
    // No new SQL column — the bundle lives inside the existing `data`
    // JSON blob (same pattern as `theme`, `accent_color`,
    // `text_direction`, `pinned_at`, etc.). This block backfills the
    // `reader_settings_summary` indexed text column so callers that
    // need to filter on it (e.g. "leaves with a dark variant") can
    // scan without parsing every row's full data blob. Per-leaf
    // typography overrides (font_scale, font_family, bold,
    // line/letter/word spacing, margin_scale, justify,
    // theme_dark_variant, custom_layout_enabled) are stored as a
    // single JSON struct under the `reader_settings` key of the
    // leaf's `data` payload. `#[serde(default)]` on the Rust struct
    // keeps backward compat — pre-v15 rows decode with `None`.
    add_column_if_missing(conn, "leaves", "reader_settings_json", "TEXT")?;
    conn.execute(
        "UPDATE leaves
            SET reader_settings_json = json_extract(data, '$.reader_settings')
          WHERE reader_settings_json IS NULL
            AND json_extract(data, '$.reader_settings') IS NOT NULL",
        [],
    )
    .map_err(|e| PinkhaError::Db(e.to_string()))?;
    conn.pragma_update(None, "user_version", 15)
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

#[cfg(test)]
mod tests {
    use super::*;

    fn migrated() -> Connection {
        let mut conn = Connection::open_in_memory().expect("open in-memory db");
        apply_migrations(&mut conn).expect("apply migrations");
        conn
    }

    fn index_names(conn: &Connection) -> Vec<String> {
        let mut stmt = conn
            .prepare("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_%' ORDER BY name")
            .expect("prepare");
        let rows = stmt
            .query_map([], |row| row.get::<_, String>(0))
            .expect("query");
        rows.map(|r| r.expect("row")).collect()
    }

    /// The indexes are what keep every list query off a full table scan.
    /// Losing one would be invisible until a user with a large library
    /// noticed the app had gone sluggish, so pin them by name.
    #[test]
    fn creates_every_expected_index() {
        let conn = migrated();
        let names = index_names(&conn);
        for expected in [
            "idx_books_active_updated",
            "idx_leaves_active_updated",
            "idx_leaves_parent",
            "idx_leaves_pinned",
            "idx_leaves_shelf",
            "idx_shelves_active",
            "idx_shelves_parent",
        ] {
            assert!(
                names.iter().any(|n| n == expected),
                "missing index {expected}; have {names:?}"
            );
        }
    }

    /// The listing query must be served by the index *and* have its sort
    /// eliminated — `(deleted_at, updated_at DESC)` exists precisely so
    /// SQLite never builds a temp B-tree for the ORDER BY.
    #[test]
    fn listing_query_uses_the_index_and_skips_the_sort() {
        let conn = migrated();
        let plan: String = conn
            .prepare(
                "EXPLAIN QUERY PLAN
                 SELECT id FROM leaves WHERE deleted_at IS NULL ORDER BY updated_at DESC",
            )
            .expect("prepare")
            .query_map([], |row| row.get::<_, String>(3))
            .expect("query")
            .map(|r| r.expect("row"))
            .collect::<Vec<_>>()
            .join(" | ");

        assert!(
            plan.contains("idx_leaves_active_updated"),
            "listing should use the covering index, plan was: {plan}"
        );
        assert!(
            !plan.contains("TEMP B-TREE"),
            "listing should not sort, plan was: {plan}"
        );
    }

    /// `apply_migrations` runs unconditionally on every launch — three
    /// times per cold start, in fact, since each store constructs it. Every
    /// statement in it has to be safe to replay.
    #[test]
    fn is_idempotent_across_repeated_runs() {
        let mut conn = Connection::open_in_memory().expect("open");
        for _ in 0..3 {
            apply_migrations(&mut conn).expect("re-apply");
        }
        assert_eq!(index_names(&conn).len(), 7);
        let version: i64 = conn
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .expect("read user_version");
        assert_eq!(version, 16);
    }

    /// A leaf whose `shelf_id` column and JSON blob disagree gets healed,
    /// column-authoritative — including when it sits in Compost, which an
    /// earlier version of this migration wrongly skipped.
    #[test]
    fn heals_shelf_id_divergence_including_trashed_rows() {
        let mut conn = Connection::open_in_memory().expect("open");
        apply_migrations(&mut conn).expect("initial");

        // Column says "in shelf S", blob says "no shelf" — and it's trashed.
        conn.execute(
            "INSERT INTO leaves (id, title_text, title_json, updated_at, created_at,
                                 published_at, shelf_id, deleted_at, data)
             VALUES ('leaf-1', 'T', '[]', 'now', 'now', 'now', 'shelf-1', 'yesterday',
                     json_object('id','leaf-1','shelf_id', json('null')))",
            [],
        )
        .expect("seed divergent trashed row");

        apply_migrations(&mut conn).expect("re-apply heals");

        let blob_shelf: Option<String> = conn
            .query_row(
                "SELECT json_extract(data, '$.shelf_id') FROM leaves WHERE id = 'leaf-1'",
                [],
                |r| r.get(0),
            )
            .expect("read blob");
        assert_eq!(
            blob_shelf.as_deref(),
            Some("shelf-1"),
            "trashed rows are healed too — restore() would otherwise re-trigger the bug"
        );
    }
}
