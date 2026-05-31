use crate::application::error::PinkhaError;
use rusqlite::Connection;

pub fn appliquer_migrations(conn: &mut Connection) -> Result<(), PinkhaError> {
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

    ajouter_colonne_si_absente(conn, "documents", "created_at", "TEXT NOT NULL DEFAULT ''")?;
    ajouter_colonne_si_absente(conn, "databases", "created_at", "TEXT NOT NULL DEFAULT ''")?;
    conn.pragma_update(None, "user_version", 4)
        .map_err(|e| PinkhaError::Db(e.to_string()))?;
    Ok(())
}

pub fn appliquer_migrations_documents(conn: &mut Connection) -> Result<(), PinkhaError> {
    appliquer_migrations(conn)
}

pub fn appliquer_migrations_databases(conn: &mut Connection) -> Result<(), PinkhaError> {
    appliquer_migrations(conn)
}

fn ajouter_colonne_si_absente(
    conn: &Connection,
    table: &str,
    colonne: &str,
    definition: &str,
) -> Result<(), PinkhaError> {
    let mut stmt = conn
        .prepare(&format!("PRAGMA table_info({table})"))
        .map_err(|e| PinkhaError::Db(e.to_string()))?;
    let colonnes = stmt
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|e| PinkhaError::Db(e.to_string()))?;

    for nom in colonnes {
        if nom.map_err(|e| PinkhaError::Db(e.to_string()))? == colonne {
            return Ok(());
        }
    }

    conn.execute_batch(&format!(
        "ALTER TABLE {table} ADD COLUMN {colonne} {definition};"
    ))
    .map_err(|e| PinkhaError::Db(e.to_string()))
}
