#![allow(dead_code)]
use crate::domain::document::InlineText;
use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use uuid::Uuid;

// ── Types de propriétés (colonnes) ───────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum Aggregate {
    Count,
    Sum,
    Average,
    Min,
    Max,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum PropertyType {
    Title,
    Text,
    Number,
    Selection(Vec<String>),
    SelectionMultiple(Vec<String>),
    Date,
    Checkbox,
    Url,
    Relation {
        db_id: Uuid,
    },
    Rollup {
        relation_prop_id: Uuid,
        target_prop_id: Uuid,
        aggregate: Aggregate,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Property {
    pub id: Uuid,
    pub name: String,
    pub type_: PropertyType,
}

impl Property {
    pub fn new(name: impl Into<String>, type_: PropertyType) -> Self {
        Self {
            id: Uuid::new_v4(),
            name: name.into(),
            type_,
        }
    }
}

// ── Valeurs des cellules ─────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum PropertyValue {
    Title(Vec<InlineText>),
    Text(String),
    Number(f64),
    Selection(Option<String>),
    SelectionMultiple(Vec<String>),
    Date(String), // ISO 8601
    Checkbox(bool),
    Url(String),
    Relation(Vec<Uuid>), // IDs d'entrées dans la database liée
    Empty,
}

// ── Entrées (lignes) ─────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    pub id: Uuid,
    /// Timestamp ISO 8601 auto-généré à la création — jamais modifié après.
    #[serde(default)]
    pub created_at: String,
    pub values: HashMap<Uuid, PropertyValue>,
}

impl Entry {
    pub fn new(values: HashMap<Uuid, PropertyValue>) -> Self {
        Self {
            id: Uuid::new_v4(),
            created_at: Utc::now().to_rfc3339(),
            values,
        }
    }
}

// ── Views ─────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ViewType {
    Table,
    Kanban { group_by: Uuid },
    Calendar { property_id: Uuid },
    Gallery,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum FilterCondition {
    Equal(PropertyValue),
    Contains(String),
    IsEmpty,
    IsFilled,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Filter {
    pub property_id: Uuid,
    pub condition: FilterCondition,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum Order {
    Ascending,
    Descending,
}

/// Détermine quelle date utiliser lors d'un tri.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub enum SortSource {
    /// Sort standard sur la valeur de `property_id`.
    #[default]
    Property,
    /// Sort sur `created_at` uniquement (date auto-générée, `property_id` ignoré).
    Created,
    /// Utilise la valeur de `property_id` si elle est renseignée, sinon `created_at`.
    /// Résout le cas journal : anciennes notes avec date manuelle + news notes sans.
    ManualThenCreated,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Sort {
    pub property_id: Uuid,
    pub order: Order,
    #[serde(default)]
    pub source: SortSource,
}

impl Sort {
    pub fn by_property(property_id: Uuid, order: Order) -> Self {
        Self {
            property_id,
            order,
            source: SortSource::Property,
        }
    }

    /// Sort par date auto-générée. `property_id` peut être `Uuid::nil()`.
    pub fn by_creation(order: Order) -> Self {
        Self {
            property_id: Uuid::nil(),
            order,
            source: SortSource::Created,
        }
    }

    /// Date manuelle si renseignée, sinon date de création automatique.
    pub fn manual_then_creation(property_id: Uuid, order: Order) -> Self {
        Self {
            property_id,
            order,
            source: SortSource::ManualThenCreated,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct View {
    pub id: Uuid,
    pub name: String,
    pub type_: ViewType,
    pub filters: Vec<Filter>,
    pub sorts: Vec<Sort>,
}

impl View {
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

// ── Groupment ───────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Group {
    pub value: PropertyValue, // valeur commune du groupe (Empty = sans valeur)
    pub entries: Vec<Entry>,
}

// ── Database ─────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DatabaseMeta {
    pub id: Uuid,
    pub title: Vec<InlineText>,
    /// Timestamp ISO 8601 de la dernière modification — géré par l'infrastructure.
    /// Empty si le backend ne le fournit pas (DatabaseStore JSON, mock).
    #[serde(default)]
    pub updated_at: String,
    /// Timestamp ISO 8601 de création — setté à l'INSERT, jamais modifié.
    /// Empty si le backend ne le fournit pas (DatabaseStore JSON, mock).
    #[serde(default)]
    pub created_at: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Database {
    pub id: Uuid,
    pub title: Vec<InlineText>,
    pub properties: Vec<Property>,
    pub entries: Vec<Entry>,
    pub views: Vec<View>,
}

impl Database {
    pub fn new(title: Vec<InlineText>, properties: Vec<Property>) -> Self {
        let vue_defaut = View::new("Table", ViewType::Table);
        Self {
            id: Uuid::new_v4(),
            title,
            properties,
            entries: vec![],
            views: vec![vue_defaut],
        }
    }

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
        // ISO 8601 commence par l'année
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
