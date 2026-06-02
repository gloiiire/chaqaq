use crate::domain::database::property::PropertyValue;
use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use uuid::Uuid;

/// A single row in a database.
///
/// `document_id` links the row back to a full Pinkha [`Document`] when the
/// row represents a page (Notion-style — every row IS a page). When set,
/// orchestration code propagates Title changes from the row to the document
/// so renaming a row in the DB view also renames the underlying note.
/// `None` for rows that are pure tabular data without an attached page.
///
/// [`Document`]: crate::domain::document::Document
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    /// Unique identifier for this entry.
    pub id: Uuid,
    /// ISO 8601 timestamp automatically set at creation — never modified afterwards.
    #[serde(default)]
    pub created_at: String,
    /// Cell values keyed by property ID.
    pub values: HashMap<Uuid, PropertyValue>,
    /// Optional link to the [`Document`] this row represents. `#[serde(default)]`
    /// keeps the field backward-compatible with entries serialised before it existed.
    ///
    /// [`Document`]: crate::domain::document::Document
    #[serde(default)]
    pub document_id: Option<Uuid>,
    /// Soft-delete timestamp. `None` when the entry is live; `Some(iso8601)`
    /// when it has been deleted but is still recoverable. Soft-deleted entries
    /// are filtered out of `query` / `query_with_rollups` / `search_entries` /
    /// `grouped_query` and don't appear in normal views. `#[serde(default)]`
    /// keeps the field backward-compatible with pre-soft-delete entries.
    #[serde(default)]
    pub deleted_at: Option<String>,
}

impl Entry {
    /// Creates a new standalone entry (no document attached).
    pub fn new(values: HashMap<Uuid, PropertyValue>) -> Self {
        Self {
            id: Uuid::new_v4(),
            created_at: Utc::now().to_rfc3339(),
            values,
            document_id: None,
            deleted_at: None,
        }
    }

    /// Creates a new entry linked to an existing document — used by import
    /// pipelines (Notion, Craft) where every page becomes both a Document and
    /// a row in its parent database.
    pub fn with_document(values: HashMap<Uuid, PropertyValue>, document_id: Uuid) -> Self {
        Self {
            id: Uuid::new_v4(),
            created_at: Utc::now().to_rfc3339(),
            values,
            document_id: Some(document_id),
            deleted_at: None,
        }
    }

    /// `true` when this entry has been soft-deleted.
    pub fn is_deleted(&self) -> bool {
        self.deleted_at.is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_entry_new_genere_id_unique() {
        let e1 = Entry::new(HashMap::new());
        let e2 = Entry::new(HashMap::new());
        assert_ne!(e1.id, e2.id);
    }

    #[test]
    fn test_entry_new_a_created_at_non_vide() {
        let e = Entry::new(HashMap::new());
        assert!(!e.created_at.is_empty());
        // ISO 8601 starts with the year
        assert!(e.created_at.starts_with("20"));
    }
}
