use crate::domain::book::entry::Entry;
use crate::domain::book::property::PropertyValue;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Layout used to display the entries of a book.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ViewType {
    /// Vertical list of cards — mobile-first default. Each row is one
    /// entry rendered as icon + title + inline metadata (tags / date)
    /// stacked under the title. Tapping the row opens the linked doc.
    List,
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
    /// Sort on `published_at` — the user-editable publish date. Defaults to
    /// `created_at` on insert, so untouched entries behave like `Created` ;
    /// the difference shows up the moment the user overrides the publish
    /// date for an entry. `property_id` is ignored.
    Published,
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

    /// Builds a sort rule that orders entries by their user-editable
    /// `published_at` timestamp. `property_id` can be `Uuid::nil()`.
    pub fn by_published(order: Order) -> Self {
        Self {
            property_id: Uuid::nil(),
            order,
            source: SortSource::Published,
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

/// Where the date used for grouping comes from. Mirrors the
/// vocabulary of [`SortSource`] so users get the same options here
/// as in the sort menu, plus an explicit property pointer for date
/// columns that don't make sense as a sort source.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum DateGroupingSource {
    /// Use each entry's auto-generated `created_at`.
    Created,
    /// Use each entry's user-editable `published_at` (falls back to
    /// `created_at` when blank).
    Published,
    /// Use the value of the given Date property. Cells that are
    /// missing or empty fall into the "No date" bucket.
    Property(Uuid),
}

/// How fine-grained the date buckets are. `YearMonth` is the only
/// hierarchical variant ; the others are flat one-level trees.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub enum DateGranularity {
    /// One bucket per calendar year, e.g. `2024`, `2025`.
    Year,
    /// One bucket per calendar month, e.g. `January 2024`. Flat.
    Month,
    /// Two-level tree : year header > month sub-header.
    YearMonth,
    /// One bucket per calendar day, e.g. `January 15, 2024`. Flat.
    Day,
}

/// Date-based grouping configuration attached to a [`View`]. When
/// `Some`, the rendered list partitions entries into chronological
/// buckets — distinct from the existing property-based grouping
/// surfaced by `groupByPropertyId` on the UI side, which targets
/// Select / Checkbox columns instead.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DateGrouping {
    pub source: DateGroupingSource,
    pub granularity: DateGranularity,
    /// Order of the top-level groups. `false` = newest first
    /// (calendar-style default).
    pub ascending: bool,
}

/// A named view of a book with its own filters and sort rules.
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
    /// Optional date-based grouping config. Applied *after* filters
    /// and sorts so the intra-bucket order honours the user's sort
    /// rules. `#[serde(default)]` keeps every pre-existing view in
    /// the SQLite store decoding cleanly.
    #[serde(default)]
    pub date_grouping: Option<DateGrouping>,
}

impl View {
    /// Creates a new view with no filters, sort rules, or date grouping.
    pub fn new(name: impl Into<String>, type_: ViewType) -> Self {
        Self {
            id: Uuid::new_v4(),
            name: name.into(),
            type_,
            filters: vec![],
            sorts: vec![],
            date_grouping: None,
        }
    }
}

/// A set of entries sharing the same value for the grouping property.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Group {
    /// Common property value for this group (`Empty` = entries with no value).
    pub value: PropertyValue,
    /// Entries belonging to this group.
    pub entries: Vec<Entry>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_vue_new_sans_filters_ni_sorts() {
        let vue = View::new("Board", ViewType::Gallery);
        assert!(vue.filters.is_empty());
        assert!(vue.sorts.is_empty());
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
        use crate::domain::book::entry::Entry;
        use std::collections::HashMap;
        let groupe = Group {
            value: PropertyValue::Text("En cours".to_string()),
            entries: vec![Entry::new(HashMap::new())],
        };
        assert_eq!(groupe.entries.len(), 1);
    }

    #[test]
    fn date_grouping_defaults_to_none() {
        let v = View::new("List", ViewType::List);
        assert!(v.date_grouping.is_none());
    }

    #[test]
    fn date_grouping_round_trips_through_serde() {
        let mut v = View::new("By month", ViewType::List);
        v.date_grouping = Some(DateGrouping {
            source: DateGroupingSource::Published,
            granularity: DateGranularity::YearMonth,
            ascending: false,
        });
        let json = serde_json::to_string(&v).unwrap();
        let back: View = serde_json::from_str(&json).unwrap();
        assert_eq!(back, v);
    }

    #[test]
    fn date_grouping_deserialises_legacy_view_without_field() {
        // A view persisted before the date_grouping field existed must
        // still decode — the #[serde(default)] guard keeps it nil.
        let legacy = r#"{"id":"00000000-0000-0000-0000-000000000000","name":"X","type_":"List","filters":[],"sorts":[]}"#;
        let v: View = serde_json::from_str(legacy).unwrap();
        assert!(v.date_grouping.is_none());
    }
}
