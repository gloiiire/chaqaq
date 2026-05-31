// ── Bear SQLite row types ─────────────────────────────────────────────────────
//
// Column names match the Core Data-generated SQLite schema used by Bear.
// Only the columns actually read by the extractor are listed.

/// A single note row from Bear's `ZSFNOTE` table.
#[derive(Debug, Clone)]
pub struct BearNote {
    /// Core Data primary key (integer).
    pub id: i64,
    /// Note title (duplicated as the first `# Heading` in `text`).
    pub title: String,
    /// Full note body in Bear's Markdown dialect.
    pub text: String,
    /// Core Data timestamp: seconds since 2001-01-01 00:00:00 UTC.
    pub creation_date: f64,
    /// Core Data timestamp: seconds since 2001-01-01 00:00:00 UTC.
    pub modification_date: f64,
    /// Non-zero when the note is in the Trash.
    pub trashed: i64,
    /// Non-zero when the note is archived.
    pub archived: i64,
}
