use crate::domain::database::entry::Entry;
use crate::domain::database::property::Property;
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
    /// Column definitions.
    pub properties: Vec<Property>,
    /// Rows.
    pub entries: Vec<Entry>,
    /// Named views (filters + sorts + layout).
    pub views: Vec<View>,
}

impl Database {
    /// Creates a new database with a default Table view and no entries.
    pub fn new(title: Vec<InlineText>, properties: Vec<Property>) -> Self {
        let default_view = View::new("Table", ViewType::Table);
        Self {
            id: Uuid::new_v4(),
            title,
            properties,
            entries: vec![],
            views: vec![default_view],
        }
    }

    /// Returns a lightweight `DatabaseMeta` snapshot (timestamps left empty).
    pub fn meta(&self) -> DatabaseMeta {
        DatabaseMeta {
            id: self.id,
            title: self.title.clone(),
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
    fn test_new_database_a_vue_tableau_par_defaut() {
        let db = Database::new(title("Projets"), vec![]);
        assert_eq!(db.views.len(), 1);
        assert_eq!(db.views[0].type_, ViewType::Table);
        assert_eq!(db.views[0].name, "Table");
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
