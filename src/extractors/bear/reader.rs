// ── Bear SQLite reader ─────────────────────────────────────────────────────────
//
// Opens Bear's book in read-only mode. The caller is responsible for
// obtaining user consent (via a Swift file picker) before passing the path.

use rusqlite::{Connection, OpenFlags};

use super::schema::BearNote;
use crate::application::error::PinkhaError;
use crate::extractors::ExtractorError;

/// Read-only connection to Bear's `book.sqlite`.
pub struct BearReader {
    conn: Connection,
}

impl BearReader {
    /// Opens the Bear SQLite file in read-only mode.
    pub fn new(db_path: &str) -> Result<Self, ExtractorError> {
        let conn = Connection::open_with_flags(
            db_path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .map_err(|e| ExtractorError::Storage(PinkhaError::Db(e.to_string())))?;

        Ok(Self { conn })
    }

    /// Fetches all non-trashed notes ordered by most recently modified first.
    pub fn fetch_notes(&self) -> Result<Vec<BearNote>, ExtractorError> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT Z_PK, ZTITLE, ZTEXT, ZCREATIONDATE, ZMODIFICATIONDATE, \
                        ZTRASHED, ZARCHIVED \
                   FROM ZSFNOTE \
                  WHERE ZTRASHED = 0 \
                  ORDER BY ZMODIFICATIONDATE DESC",
            )
            .map_err(|e| ExtractorError::Storage(PinkhaError::Db(e.to_string())))?;

        let notes = stmt
            .query_map([], |row| {
                Ok(BearNote {
                    id: row.get(0)?,
                    title: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                    text: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
                    creation_date: row.get::<_, Option<f64>>(3)?.unwrap_or(0.0),
                    modification_date: row.get::<_, Option<f64>>(4)?.unwrap_or(0.0),
                    trashed: row.get::<_, Option<i64>>(5)?.unwrap_or(0),
                    archived: row.get::<_, Option<i64>>(6)?.unwrap_or(0),
                })
            })
            .map_err(|e| ExtractorError::Storage(PinkhaError::Db(e.to_string())))?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| ExtractorError::Storage(PinkhaError::Db(e.to_string())))?;

        Ok(notes)
    }

    /// Returns the tag names associated with a given note.
    pub fn fetch_tags_for_note(&self, note_id: i64) -> Result<Vec<String>, ExtractorError> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT t.ZTITLE \
                   FROM ZSFNOTETAG nt \
                   JOIN ZSFTAG t ON t.Z_PK = nt.Z_7TAGS \
                  WHERE nt.Z_7NOTES = ?1",
            )
            .map_err(|e| ExtractorError::Storage(PinkhaError::Db(e.to_string())))?;

        let tags = stmt
            .query_map([note_id], |row| {
                Ok(row.get::<_, Option<String>>(0)?.unwrap_or_default())
            })
            .map_err(|e| ExtractorError::Storage(PinkhaError::Db(e.to_string())))?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| ExtractorError::Storage(PinkhaError::Db(e.to_string())))?;

        Ok(tags)
    }
}
