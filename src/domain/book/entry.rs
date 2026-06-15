use crate::domain::book::property::PropertyValue;
use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use uuid::Uuid;

/// A single row in a book.
///
/// `leaf_id` links the row back to a full Pinkha [`Leaf`] when the
/// row represents a page (Notion-style — every row IS a page). When set,
/// orchestration code propagates Title changes from the row to the leaf
/// so renaming a row in the DB view also renames the underlying note.
/// `None` for rows that are pure tabular data without an attached page.
///
/// [`Leaf`]: crate::domain::leaf::Leaf
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    /// Unique identifier for this entry.
    pub id: Uuid,
    /// ISO 8601 timestamp automatically set at creation — never modified afterwards.
    #[serde(default)]
    pub created_at: String,
    /// User-editable publish timestamp. Defaults to `created_at` at
    /// insert (so untouched entries behave exactly like before), but
    /// the user can override it to surface an entry as if it were
    /// published on a different date — useful for journals where a
    /// page is *written* one day but leaves an *event* from
    /// another. Backward-compatible : empty string on existing rows
    /// is treated as "fall back to `created_at`" by the query path.
    #[serde(default)]
    pub published_at: String,
    /// Cell values keyed by property ID.
    pub values: HashMap<Uuid, PropertyValue>,
    /// Optional link to the [`Leaf`] this row represents. `#[serde(default)]`
    /// keeps the field backward-compatible with entries serialised before it existed.
    ///
    /// [`Leaf`]: crate::domain::leaf::Leaf
    #[serde(default)]
    pub leaf_id: Option<Uuid>,
    /// Soft-delete timestamp. `None` when the entry is live; `Some(iso8601)`
    /// when it has been deleted but is still recoverable. Soft-deleted entries
    /// are filtered out of `query` / `query_with_rollups` / `search_entries` /
    /// `grouped_query` and don't appear in normal views. `#[serde(default)]`
    /// keeps the field backward-compatible with pre-soft-delete entries.
    #[serde(default)]
    pub deleted_at: Option<String>,
}

impl Entry {
    /// Creates a new standalone entry (no leaf attached).
    pub fn new(values: HashMap<Uuid, PropertyValue>) -> Self {
        let now = Utc::now().to_rfc3339();
        Self {
            id: Uuid::new_v4(),
            created_at: now.clone(),
            published_at: now,
            values,
            leaf_id: None,
            deleted_at: None,
        }
    }

    /// Creates a new entry linked to an existing leaf — used by import
    /// pipelines (Notion, Craft) where every page becomes both a Leaf and
    /// a row in its parent book.
    pub fn with_leaf(values: HashMap<Uuid, PropertyValue>, leaf_id: Uuid) -> Self {
        let now = Utc::now().to_rfc3339();
        Self {
            id: Uuid::new_v4(),
            created_at: now.clone(),
            published_at: now,
            values,
            leaf_id: Some(leaf_id),
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
