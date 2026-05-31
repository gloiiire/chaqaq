use crate::domain::database::property::PropertyValue;
use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use uuid::Uuid;

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
