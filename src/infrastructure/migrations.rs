use rusqlite::Connection;
use rusqlite_migration::{Migrations, M};
use crate::application::error::ChaqaqError;

pub fn appliquer_migrations_documents(conn: &mut Connection) -> Result<(), ChaqaqError> {
    Migrations::new(vec![
        M::up(
            "CREATE TABLE documents (
                id          TEXT PRIMARY KEY,
                title_text  TEXT NOT NULL DEFAULT '',
                title_json  TEXT NOT NULL DEFAULT '[]',
                cover       TEXT,
                updated_at  TEXT NOT NULL,
                deleted_at  TEXT,
                data        TEXT NOT NULL
            );"
        ),
    ])
    .to_latest(conn)
    .map_err(|e| ChaqaqError::Db(e.to_string()))
}

pub fn appliquer_migrations_databases(conn: &mut Connection) -> Result<(), ChaqaqError> {
    Migrations::new(vec![
        M::up(
            "CREATE TABLE databases (
                id          TEXT PRIMARY KEY,
                title_text  TEXT NOT NULL DEFAULT '',
                title_json  TEXT NOT NULL DEFAULT '[]',
                updated_at  TEXT NOT NULL,
                deleted_at  TEXT,
                data        TEXT NOT NULL
            );"
        ),
    ])
    .to_latest(conn)
    .map_err(|e| ChaqaqError::Db(e.to_string()))
}
