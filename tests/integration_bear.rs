// ── Bear extractor — integration tests ───────────────────────────────────────
//
// Creates a temporary SQLite file with the Bear schema, seeds test notes, and
// verifies that `BearReader` filters trashed notes correctly.

use std::path::PathBuf;

use pinkha::extractors::bear::reader::BearReader;
use uuid::Uuid;

/// Creates a temporary SQLite file with the minimal Bear schema and returns
/// its path.  The caller is responsible for deleting it.
fn create_bear_db(path: &PathBuf) -> Result<(), rusqlite::Error> {
    let conn = rusqlite::Connection::open(path)?;

    conn.execute_batch(
        "CREATE TABLE ZSFNOTE (
            Z_PK                INTEGER PRIMARY KEY,
            ZTITLE              TEXT,
            ZTEXT               TEXT,
            ZTRASHED            INTEGER NOT NULL DEFAULT 0,
            ZARCHIVED           INTEGER NOT NULL DEFAULT 0,
            ZCREATIONDATE       REAL,
            ZMODIFICATIONDATE   REAL
        );",
    )?;

    // Note 1: normal (not trashed).
    conn.execute(
        "INSERT INTO ZSFNOTE (Z_PK, ZTITLE, ZTEXT, ZTRASHED, ZCREATIONDATE, ZMODIFICATIONDATE)
         VALUES (1, 'First note', '# First note\nBody text.', 0, 0.0, 1.0);",
        [],
    )?;

    // Note 2: trashed — must be excluded by `fetch_notes`.
    conn.execute(
        "INSERT INTO ZSFNOTE (Z_PK, ZTITLE, ZTEXT, ZTRASHED, ZCREATIONDATE, ZMODIFICATIONDATE)
         VALUES (2, 'Trashed note', '# Trashed note\nShould not appear.', 1, 0.0, 2.0);",
        [],
    )?;

    Ok(())
}

/// Provides a unique temporary file path and ensures it is removed afterwards
/// even if the test panics.
struct TempFile {
    path: PathBuf,
}

impl TempFile {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("pinkha_bear_test_{}.sqlite", Uuid::new_v4()));
        Self { path }
    }
}

impl Drop for TempFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[test]
fn test_bear_reader_skips_trashed_notes() -> Result<(), Box<dyn std::error::Error>> {
    let tmp = TempFile::new();

    create_bear_db(&tmp.path).map_err(|e| format!("schema setup failed: {e}"))?;

    let reader = BearReader::new(tmp.path.to_str().ok_or("non-UTF-8 path")?)?;

    let notes = reader.fetch_notes()?;

    // Only the non-trashed note should be returned.
    assert_eq!(notes.len(), 1, "expected exactly 1 non-trashed note");
    assert_eq!(notes[0].title, "First note");
    assert_eq!(notes[0].trashed, 0);

    Ok(())
}

#[test]
fn test_bear_reader_note_fields() -> Result<(), Box<dyn std::error::Error>> {
    let tmp = TempFile::new();

    create_bear_db(&tmp.path).map_err(|e| format!("schema setup failed: {e}"))?;

    let reader = BearReader::new(tmp.path.to_str().ok_or("non-UTF-8 path")?)?;

    let notes = reader.fetch_notes()?;
    assert_eq!(notes.len(), 1);

    let note = &notes[0];
    assert_eq!(note.id, 1);
    assert!(
        note.text.contains("Body text."),
        "note body should contain text"
    );
    assert_eq!(note.creation_date, 0.0);
    assert_eq!(note.modification_date, 1.0);

    Ok(())
}
