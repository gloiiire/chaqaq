use std::collections::HashMap;

use crate::domain::database::entry::Entry;
use crate::domain::database::property::Property;
use crate::domain::database::property::PropertyValue;
use crate::domain::database::view::{View, ViewType};
use crate::domain::document::InlineText;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Lightweight database descriptor returned by list operations.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DatabaseMeta {
    /// Database identifier.
    pub id: Uuid,
    /// Rich-text title.
    pub title: Vec<InlineText>,
    /// Optional cover image identifier (URL or local filename).
    /// Mirrors `DocumentMeta.cover` so list rows can render a thumbnail.
    #[serde(default)]
    pub cover: Option<String>,
    /// Optional icon (emoji / filename / URL) shown next to the title.
    #[serde(default)]
    pub icon: Option<String>,
    /// ISO 8601 timestamp of the last modification, managed by the infrastructure layer.
    /// Empty when the backend does not provide it (JSON store, mock).
    #[serde(default)]
    pub updated_at: String,
    /// ISO 8601 creation timestamp, set at INSERT and never modified.
    /// Empty when the backend does not provide it (JSON store, mock).
    #[serde(default)]
    pub created_at: String,
}

/// A Notion-style database: properties (columns), entries (rows), and views.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Database {
    /// Database identifier.
    pub id: Uuid,
    /// Rich-text title.
    pub title: Vec<InlineText>,
    /// Optional cover image identifier (URL or local filename). Renders
    /// as the database's banner in the doc-like header, same shape as
    /// `Document.cover`.
    #[serde(default)]
    pub cover: Option<String>,
    /// Optional emoji / filename / URL displayed next to the title in
    /// the header and in the parent list. Defaults to `None` (the UI
    /// falls back to a built-in tablecells / list icon).
    #[serde(default)]
    pub icon: Option<String>,
    /// Optional rich-text description rendered below the title in the
    /// header. Defaults empty.
    #[serde(default)]
    pub description: Vec<InlineText>,
    /// Read-only flag — when `true`, every editor surface in the UI
    /// renders blocked-out (no toolbar, no add buttons, no swipe).
    /// Mirrors `Document.locked` so users keep the same mental model.
    #[serde(default)]
    pub locked: bool,
    /// When set, the Date property identified here drives every entry's
    /// `published_at`: adopting the column backfills existing rows, and
    /// later edits to a cell of this column keep the row's publish date
    /// in sync. `None` = publish dates follow `created_at` unless the
    /// user overrides a row manually.
    #[serde(default)]
    pub published_at_source: Option<Uuid>,
    /// Column definitions.
    pub properties: Vec<Property>,
    /// Rows.
    pub entries: Vec<Entry>,
    /// Named views (filters + sorts + layout).
    pub views: Vec<View>,
}

impl Database {
    /// Creates a new database with a default List view and no entries.
    /// List is the mobile-first default — vertical cards with title +
    /// inline metadata are friendlier on iPhone than a horizontally
    /// scrolling table.
    pub fn new(title: Vec<InlineText>, properties: Vec<Property>) -> Self {
        let default_view = View::new("List", ViewType::List);
        Self {
            id: Uuid::new_v4(),
            title,
            cover: None,
            icon: None,
            description: vec![],
            locked: false,
            published_at_source: None,
            properties,
            entries: vec![],
            views: vec![default_view],
        }
    }

    /// Publish date driven by the `published_at_source` column for the
    /// given values map. `None` when no source column is configured.
    /// `Some("")` when the source is configured but the cell is empty or
    /// not a date — the empty sentinel means "follow `created_at`".
    pub fn source_publish_date(&self, values: &HashMap<Uuid, PropertyValue>) -> Option<String> {
        let prop_id = self.published_at_source?;
        Some(match values.get(&prop_id) {
            Some(PropertyValue::Date(d)) if !d.is_empty() => d.clone(),
            _ => String::new(),
        })
    }

    /// Returns a lightweight `DatabaseMeta` snapshot (timestamps left empty).
    pub fn meta(&self) -> DatabaseMeta {
        DatabaseMeta {
            id: self.id,
            title: self.title.clone(),
            cover: self.cover.clone(),
            icon: self.icon.clone(),
            updated_at: String::new(),
            created_at: String::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::document::InlineText;

    fn title(s: &str) -> Vec<InlineText> {
        vec![InlineText {
            content: s.to_string(),
            styles: vec![],
        }]
    }

    #[test]
    fn test_new_database_a_vue_list_par_defaut() {
        let db = Database::new(title("Projets"), vec![]);
        assert_eq!(db.views.len(), 1);
        assert_eq!(db.views[0].type_, ViewType::List);
        assert_eq!(db.views[0].name, "List");
    }

    #[test]
    fn test_new_database_header_defaults_are_empty() {
        let db = Database::new(title("Empty"), vec![]);
        assert_eq!(db.cover, None);
        assert_eq!(db.icon, None);
        assert!(db.description.is_empty());
    }

    #[test]
    fn test_meta_extrait_id_et_title() {
        let db = Database::new(title("Tâches"), vec![]);
        let meta = db.meta();
        assert_eq!(meta.id, db.id);
        assert_eq!(meta.title, db.title);
    }

    #[test]
    fn test_new_database_sans_entries() {
        let db = Database::new(title("Empty"), vec![]);
        assert!(db.entries.is_empty());
    }
}
