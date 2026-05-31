#![allow(dead_code)]
use crate::domain::document::InlineText;
use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use uuid::Uuid;

// ── Property types (columns) ─────────────────────────────────────────────────

/// Aggregation function applied to a Rollup column.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum Aggregate {
    /// Number of linked entries.
    Count,
    /// Sum of numeric values.
    Sum,
    /// Arithmetic mean of numeric values.
    Average,
    /// Minimum numeric value.
    Min,
    /// Maximum numeric value.
    Max,
}

/// Determines the data type and behaviour of a database column.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum PropertyType {
    /// Primary title column — stores rich text.
    Title,
    /// Plain text.
    Text,
    /// Floating-point number.
    Number,
    /// Single-choice dropdown; carries the list of allowed options.
    Selection(Vec<String>),
    /// Multi-choice dropdown; carries the list of allowed options.
    SelectionMultiple(Vec<String>),
    /// Date stored as an ISO 8601 string.
    Date,
    /// Boolean checkbox.
    Checkbox,
    /// URL string.
    Url,
    /// Foreign key pointing at another database.
    Relation {
        /// ID of the target database.
        db_id: Uuid,
    },
    /// Computed column that aggregates values from a related database.
    Rollup {
        /// Property that holds the relation (foreign key).
        relation_prop_id: Uuid,
        /// Property in the related database to aggregate.
        target_prop_id: Uuid,
        /// Aggregation function to apply.
        aggregate: Aggregate,
    },
}

/// A column definition in a database.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Property {
    /// Unique identifier for this property.
    pub id: Uuid,
    /// Display name shown in the UI.
    pub name: String,
    /// Data type and configuration.
    pub type_: PropertyType,
}

impl Property {
    /// Creates a new property with a freshly generated UUID.
    pub fn new(name: impl Into<String>, type_: PropertyType) -> Self {
        Self {
            id: Uuid::new_v4(),
            name: name.into(),
            type_,
        }
    }
}

// ── Cell values ──────────────────────────────────────────────────────────────

/// The value stored in a cell for a given property.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum PropertyValue {
    /// Rich text value for a `Title` property.
    Title(Vec<InlineText>),
    /// Plain text value.
    Text(String),
    /// Numeric value.
    Number(f64),
    /// Selected option for a single-choice property (`None` = nothing selected).
    Selection(Option<String>),
    /// Selected options for a multi-choice property.
    SelectionMultiple(Vec<String>),
    /// ISO 8601 date string.
    Date(String),
    /// Boolean checkbox state.
    Checkbox(bool),
    /// URL string.
    Url(String),
    /// Entry IDs in the linked database (foreign keys).
    Relation(Vec<Uuid>),
    /// No value — cell is blank.
    Empty,
}

// ── Entries (rows) ───────────────────────────────────────────────────────────

/// A single row in a database.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    /// Unique identifier for this entry.
    pub id: Uuid,
    /// ISO 8601 timestamp automatically set at creation — never modified afterwards.
    #[serde(default)]
    pub created_at: String,
    /// Cell values keyed by property ID.
    pub values: HashMap<Uuid, PropertyValue>,
}

impl Entry {
    /// Creates a new entry with a freshly generated UUID and the current UTC timestamp.
    pub fn new(values: HashMap<Uuid, PropertyValue>) -> Self {
        Self {
            id: Uuid::new_v4(),
            created_at: Utc::now().to_rfc3339(),
            values,
        }
    }
}

// ── Views ─────────────────────────────────────────────────────────────────────

/// Layout used to display the entries of a database.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ViewType {
    /// Spreadsheet-style row/column grid.
    Table,
    /// Kanban board grouped by a property.
    Kanban {
        /// Property used to define the board columns.
        group_by: Uuid,
    },
    /// Calendar layout driven by a date property.
    Calendar {
        /// Date property that positions entries on the calendar.
        property_id: Uuid,
    },
    /// Card gallery layout.
    Gallery,
}

/// Condition used to include or exclude entries from a view.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum FilterCondition {
    /// Cell value must exactly equal the given value.
    Equal(PropertyValue),
    /// Cell text must contain the given substring.
    Contains(String),
    /// Cell must be empty.
    IsEmpty,
    /// Cell must contain a non-empty value.
    IsFilled,
}

/// A filter applied to a view to restrict which entries are shown.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Filter {
    /// Property this filter is applied to.
    pub property_id: Uuid,
    /// Condition that entries must satisfy.
    pub condition: FilterCondition,
}

/// Sort direction.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum Order {
    /// Smallest / earliest first.
    Ascending,
    /// Largest / most recent first.
    Descending,
}

/// Determines which date value is used when sorting.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub enum SortSource {
    /// Standard sort on the value of `property_id`.
    #[default]
    Property,
    /// Sort on `created_at` only (auto-generated date, `property_id` is ignored).
    Created,
    /// Uses the value of `property_id` when present, falls back to `created_at`.
    /// Useful for journals that mix manually-dated and auto-dated entries.
    ManualThenCreated,
}

/// A sort rule applied to a view.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Sort {
    /// Property whose value is used for ordering (may be `Uuid::nil()` for `Created` source).
    pub property_id: Uuid,
    /// Sort direction.
    pub order: Order,
    /// Which date to use when `source` is `Created` or `ManualThenCreated`.
    #[serde(default)]
    pub source: SortSource,
}

impl Sort {
    /// Builds a sort rule that orders entries by the value of `property_id`.
    pub fn by_property(property_id: Uuid, order: Order) -> Self {
        Self {
            property_id,
            order,
            source: SortSource::Property,
        }
    }

    /// Builds a sort rule that orders entries by their auto-generated creation date.
    /// `property_id` can be `Uuid::nil()`.
    pub fn by_creation(order: Order) -> Self {
        Self {
            property_id: Uuid::nil(),
            order,
            source: SortSource::Created,
        }
    }

    /// Builds a sort rule that uses the manual date property when set, otherwise `created_at`.
    pub fn manual_then_creation(property_id: Uuid, order: Order) -> Self {
        Self {
            property_id,
            order,
            source: SortSource::ManualThenCreated,
        }
    }
}

/// A named view of a database with its own filters and sort rules.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct View {
    /// Unique identifier for this view.
    pub id: Uuid,
    /// Display name shown in the UI.
    pub name: String,
    /// Layout type.
    pub type_: ViewType,
    /// Active filters (all must pass for an entry to appear).
    pub filters: Vec<Filter>,
    /// Sort rules applied in order.
    pub sorts: Vec<Sort>,
}

impl View {
    /// Creates a new view with no filters or sort rules.
    pub fn new(name: impl Into<String>, type_: ViewType) -> Self {
        Self {
            id: Uuid::new_v4(),
            name: name.into(),
            type_,
            filters: vec![],
            sorts: vec![],
        }
    }
}

// ── Grouping ─────────────────────────────────────────────────────────────────

/// A set of entries sharing the same value for the grouping property.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Group {
    /// Common property value for this group (`Empty` = entries with no value).
    pub value: PropertyValue,
    /// Entries belonging to this group.
    pub entries: Vec<Entry>,
}

// ── Database ──────────────────────────────────────────────────────────────────

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
    fn test_entry_new_genere_id_unique() {
        let e1 = Entry::new(HashMap::new());
        let e2 = Entry::new(HashMap::new());
        assert_ne!(e1.id, e2.id);
    }

    #[test]
    fn test_propriete_new_genere_id_unique() {
        let p1 = Property::new("Nom", PropertyType::Title);
        let p2 = Property::new("Nom", PropertyType::Title);
        assert_ne!(p1.id, p2.id);
    }

    #[test]
    fn test_vue_new_sans_filters_ni_sorts() {
        let vue = View::new("Board", ViewType::Gallery);
        assert!(vue.filters.is_empty());
        assert!(vue.sorts.is_empty());
    }

    #[test]
    fn test_new_database_sans_entries() {
        let db = Database::new(title("Empty"), vec![]);
        assert!(db.entries.is_empty());
    }

    #[test]
    fn test_relation_prop_type() {
        let db_id = Uuid::new_v4();
        let prop = Property::new("Tâches", PropertyType::Relation { db_id });
        assert_eq!(prop.type_, PropertyType::Relation { db_id });
    }

    #[test]
    fn test_rollup_prop_type() {
        let rel_id = Uuid::new_v4();
        let cible_id = Uuid::new_v4();
        let prop = Property::new(
            "Nb tâches",
            PropertyType::Rollup {
                relation_prop_id: rel_id,
                target_prop_id: cible_id,
                aggregate: Aggregate::Count,
            },
        );
        assert!(matches!(prop.type_, PropertyType::Rollup { .. }));
    }

    #[test]
    fn test_valeur_relation_stocke_ids() {
        let ids = vec![Uuid::new_v4(), Uuid::new_v4()];
        let v = PropertyValue::Relation(ids.clone());
        assert_eq!(v, PropertyValue::Relation(ids));
    }

    #[test]
    fn test_entry_new_a_created_at_non_vide() {
        let e = Entry::new(HashMap::new());
        assert!(!e.created_at.is_empty());
        // ISO 8601 starts with the year
        assert!(e.created_at.starts_with("20"));
    }

    #[test]
    fn test_tri_by_creation_ignore_property_id() {
        let t = Sort::by_creation(Order::Descending);
        assert_eq!(t.source, SortSource::Created);
    }

    #[test]
    fn test_tri_manual_then_creation() {
        let id = Uuid::new_v4();
        let t = Sort::manual_then_creation(id, Order::Ascending);
        assert_eq!(t.source, SortSource::ManualThenCreated);
        assert_eq!(t.property_id, id);
    }

    #[test]
    fn test_groupe_regroupe_entries() {
        let groupe = Group {
            value: PropertyValue::Text("En cours".to_string()),
            entries: vec![Entry::new(HashMap::new())],
        };
        assert_eq!(groupe.entries.len(), 1);
    }
}
