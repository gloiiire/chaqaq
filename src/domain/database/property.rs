use crate::domain::document::InlineText;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_propriete_new_genere_id_unique() {
        let p1 = Property::new("Nom", PropertyType::Title);
        let p2 = Property::new("Nom", PropertyType::Title);
        assert_ne!(p1.id, p2.id);
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
}
