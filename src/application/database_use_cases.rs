use crate::application::database_repository::DatabaseRepository;
use crate::application::error::PinkhaError;
use crate::domain::database::{
    Aggregate, FilterCondition, Database, DatabaseMeta, Entry, Filter, Group, Order, Property,
    PropertyType, SortSource, Sort, PropertyValue, View,
};
use crate::domain::document::InlineText;
use std::cmp::Ordering;
use std::collections::HashMap;
use uuid::Uuid;

/// Creates a new database with the given title and properties, then persists it.
pub fn create_database(
    repo: &dyn DatabaseRepository,
    title: Vec<InlineText>,
    properties: Vec<Property>,
) -> Result<Database, PinkhaError> {
    let db = Database::new(title, properties);
    repo.save(&db)?;
    Ok(db)
}

/// Loads a full database by ID.
pub fn get_database(repo: &dyn DatabaseRepository, id: Uuid) -> Result<Database, PinkhaError> {
    repo.load(id)
}

/// Returns lightweight metadata for all databases (no entries loaded).
pub fn list_databases(repo: &dyn DatabaseRepository) -> Result<Vec<DatabaseMeta>, PinkhaError> {
    repo.list_meta()
}

/// Deletes a database by ID.
pub fn delete_database(repo: &dyn DatabaseRepository, db_id: Uuid) -> Result<(), PinkhaError> {
    repo.delete(db_id)
}

/// Adds a new row to the database and persists.
pub fn add_entry(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    values: HashMap<Uuid, PropertyValue>,
) -> Result<Entry, PinkhaError> {
    let mut db = repo.load(db_id)?;
    let entry = Entry::new(values);
    db.entries.push(entry.clone());
    repo.save(&db)?;
    Ok(entry)
}

/// Replaces all cell values for an existing entry and persists.
pub fn update_entry(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    entry_id: Uuid,
    values: HashMap<Uuid, PropertyValue>,
) -> Result<(), PinkhaError> {
    let mut db = repo.load(db_id)?;
    let entry = db
        .entries
        .iter_mut()
        .find(|e| e.id == entry_id)
        .ok_or(PinkhaError::NotFound(entry_id))?;
    entry.values = values;
    repo.save(&db)
}

/// Removes an entry from the database and persists.
pub fn delete_entry(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    entry_id: Uuid,
) -> Result<(), PinkhaError> {
    let mut db = repo.load(db_id)?;
    let before = db.entries.len();
    db.entries.retain(|e| e.id != entry_id);
    if db.entries.len() == before {
        return Err(PinkhaError::NotFound(entry_id));
    }
    repo.save(&db)
}

/// Adds a new column definition to the database and persists.
pub fn add_property(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    property: Property,
) -> Result<(), PinkhaError> {
    let mut db = repo.load(db_id)?;
    db.properties.push(property);
    repo.save(&db)
}

/// Adds a new view to the database and persists.
pub fn add_view(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    view: View,
) -> Result<View, PinkhaError> {
    let mut db = repo.load(db_id)?;
    db.views.push(view.clone());
    repo.save(&db)?;
    Ok(view)
}

/// Returns the entries visible in a view after applying its filters and sorts.
pub fn query(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    view_id: Uuid,
) -> Result<Vec<Entry>, PinkhaError> {
    let db = repo.load(db_id)?;
    let view = db
        .views
        .iter()
        .find(|v| v.id == view_id)
        .ok_or(PinkhaError::NotFound(view_id))?;

    let mut entries: Vec<Entry> = db
        .entries
        .iter()
        .filter(|e| view.filters.iter().all(|f| apply_filter(e, f)))
        .cloned()
        .collect();

    for sort_rule in view.sorts.iter().rev() {
        entries.sort_by(|a, b| {
            let ord = match &sort_rule.source {
                SortSource::Property => {
                    let va = a
                        .values
                        .get(&sort_rule.property_id)
                        .unwrap_or(&PropertyValue::Empty);
                    let vb = b
                        .values
                        .get(&sort_rule.property_id)
                        .unwrap_or(&PropertyValue::Empty);
                    compare_values(va, vb)
                }
                SortSource::Created => a.created_at.cmp(&b.created_at),
                SortSource::ManualThenCreated => {
                    let va = a
                        .values
                        .get(&sort_rule.property_id)
                        .unwrap_or(&PropertyValue::Empty);
                    let vb = b
                        .values
                        .get(&sort_rule.property_id)
                        .unwrap_or(&PropertyValue::Empty);
                    effective_date(va, &a.created_at).cmp(effective_date(vb, &b.created_at))
                }
            };
            if sort_rule.order == Order::Descending {
                ord.reverse()
            } else {
                ord
            }
        });
    }

    Ok(entries)
}

// ── Properties ────────────────────────────────────────────────────────────────

/// Renames an existing property and persists.
pub fn rename_property(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    prop_id: Uuid,
    new_name: &str,
) -> Result<(), PinkhaError> {
    let mut db = repo.load(db_id)?;
    let prop = db
        .properties
        .iter_mut()
        .find(|p| p.id == prop_id)
        .ok_or(PinkhaError::NotFound(prop_id))?;
    prop.name = new_name.to_string();
    repo.save(&db)
}

/// Removes a property column and clears its values from all existing entries, then persists.
pub fn delete_property(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    prop_id: Uuid,
) -> Result<(), PinkhaError> {
    let mut db = repo.load(db_id)?;
    let before = db.properties.len();
    db.properties.retain(|p| p.id != prop_id);
    if db.properties.len() == before {
        return Err(PinkhaError::NotFound(prop_id));
    }
    for entry in &mut db.entries {
        entry.values.remove(&prop_id);
    }
    repo.save(&db)
}

// ── Views ─────────────────────────────────────────────────────────────────────

/// Replaces the filters and sorts of an existing view and persists.
pub fn update_view(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    view_id: Uuid,
    filters: Vec<Filter>,
    sorts: Vec<Sort>,
) -> Result<(), PinkhaError> {
    let mut db = repo.load(db_id)?;
    let view = db
        .views
        .iter_mut()
        .find(|v| v.id == view_id)
        .ok_or(PinkhaError::NotFound(view_id))?;
    view.filters = filters;
    view.sorts = sorts;
    repo.save(&db)
}

/// Removes a view and persists.
///
/// Returns `InvalidOperation` when attempting to delete the last remaining view.
pub fn delete_view(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    view_id: Uuid,
) -> Result<(), PinkhaError> {
    let mut db = repo.load(db_id)?;
    if db.views.len() <= 1 {
        return Err(PinkhaError::InvalidOperation(
            "cannot delete the last view".to_string(),
        ));
    }
    let before = db.views.len();
    db.views.retain(|v| v.id != view_id);
    if db.views.len() == before {
        return Err(PinkhaError::NotFound(view_id));
    }
    repo.save(&db)
}

// ── Search ────────────────────────────────────────────────────────────────────

/// Case-insensitive search across all text-bearing property values of a database's entries.
pub fn search_entries(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    query: &str,
) -> Result<Vec<Entry>, PinkhaError> {
    let db = repo.load(db_id)?;
    let q = query.to_lowercase();
    Ok(db
        .entries
        .into_iter()
        .filter(|e| entry_matches(e, &q))
        .collect())
}

fn entry_matches(entry: &Entry, query: &str) -> bool {
    entry.values.values().any(|v| value_contains(v, query))
}

fn value_contains(v: &PropertyValue, query: &str) -> bool {
    match v {
        PropertyValue::Text(s) => s.to_lowercase().contains(query),
        PropertyValue::Url(s) => s.to_lowercase().contains(query),
        PropertyValue::Selection(Some(s)) => s.to_lowercase().contains(query),
        PropertyValue::SelectionMultiple(vs) => {
            vs.iter().any(|s| s.to_lowercase().contains(query))
        }
        PropertyValue::Title(inlines) => inlines
            .iter()
            .any(|i| i.content.to_lowercase().contains(query)),
        _ => false,
    }
}

// ── Relations, Rollups, Aggregates, Grouping ──────────────────────────────────

/// Enriches entries with computed values for all Rollup columns.
///
/// Rollup values are not persisted — they are recalculated at read time.
pub fn evaluate_rollups(
    repo: &dyn DatabaseRepository,
    db: &Database,
    mut entries: Vec<Entry>,
) -> Result<Vec<Entry>, PinkhaError> {
    let rollups: Vec<(Uuid, Uuid, Uuid, Aggregate)> = db
        .properties
        .iter()
        .filter_map(|p| match &p.type_ {
            PropertyType::Rollup {
                relation_prop_id,
                target_prop_id,
                aggregate,
            } => Some((p.id, *relation_prop_id, *target_prop_id, aggregate.clone())),
            _ => None,
        })
        .collect();

    if rollups.is_empty() {
        return Ok(entries);
    }

    for (rollup_id, relation_prop_id, target_prop_id, aggregate) in rollups {
        let linked_db_id = db
            .properties
            .iter()
            .find(|p| p.id == relation_prop_id)
            .and_then(|p| match &p.type_ {
                PropertyType::Relation { db_id } => Some(*db_id),
                _ => None,
            })
            .ok_or(PinkhaError::NotFound(relation_prop_id))?;

        let linked_db = repo.load(linked_db_id)?;

        for entry in &mut entries {
            let linked_ids = match entry.values.get(&relation_prop_id) {
                Some(PropertyValue::Relation(ids)) => ids.clone(),
                _ => vec![],
            };
            let linked_entries: Vec<&Entry> = linked_db
                .entries
                .iter()
                .filter(|e| linked_ids.contains(&e.id))
                .collect();
            entry
                .values
                .insert(rollup_id, calculate_aggregate(&linked_entries, target_prop_id, &aggregate));
        }
    }

    Ok(entries)
}

/// Runs `query` then enriches the result with computed Rollup values.
pub fn query_with_rollups(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    view_id: Uuid,
) -> Result<Vec<Entry>, PinkhaError> {
    let db = repo.load(db_id)?;
    let entries = query(repo, db_id, view_id)?;
    evaluate_rollups(repo, &db, entries)
}

/// Aggregates all values of a numeric column across every entry in the database.
pub fn column_aggregate(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    prop_id: Uuid,
    aggregate: Aggregate,
) -> Result<PropertyValue, PinkhaError> {
    let db = repo.load(db_id)?;
    let refs: Vec<&Entry> = db.entries.iter().collect();
    Ok(calculate_aggregate(&refs, prop_id, &aggregate))
}

/// Groups the entries of a view by the value of a given property.
pub fn grouped_query(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    view_id: Uuid,
    group_by: Uuid,
) -> Result<Vec<Group>, PinkhaError> {
    let entries = query(repo, db_id, view_id)?;
    let mut map: HashMap<String, Group> = HashMap::new();

    for entry in entries {
        let value = entry
            .values
            .get(&group_by)
            .cloned()
            .unwrap_or(PropertyValue::Empty);
        let key = group_key(&value);
        map.entry(key)
            .or_insert_with(|| Group {
                value: value.clone(),
                entries: vec![],
            })
            .entries
            .push(entry);
    }

    let mut groups: Vec<Group> = map.into_values().collect();
    groups.sort_by(|a, b| compare_values(&a.value, &b.value));
    Ok(groups)
}

// ── Internal helpers ──────────────────────────────────────────────────────────

/// Returns the effective date: manual property value when set, otherwise `created_at`.
fn effective_date<'a>(v: &'a PropertyValue, created_at: &'a str) -> &'a str {
    match v {
        PropertyValue::Date(d) if !d.is_empty() => d.as_str(),
        _ => created_at,
    }
}

fn calculate_aggregate(entries: &[&Entry], prop_id: Uuid, aggregate: &Aggregate) -> PropertyValue {
    let nums: Vec<f64> = entries
        .iter()
        .filter_map(|e| e.values.get(&prop_id))
        .filter_map(|v| {
            if let PropertyValue::Number(n) = v {
                Some(*n)
            } else {
                None
            }
        })
        .collect();

    let r = match aggregate {
        Aggregate::Count => entries.len() as f64,
        Aggregate::Sum => nums.iter().sum(),
        Aggregate::Average => {
            if nums.is_empty() {
                0.0
            } else {
                nums.iter().sum::<f64>() / nums.len() as f64
            }
        }
        Aggregate::Min => nums.iter().cloned().fold(f64::INFINITY, f64::min),
        Aggregate::Max => nums.iter().cloned().fold(f64::NEG_INFINITY, f64::max),
    };
    PropertyValue::Number(r)
}

fn group_key(v: &PropertyValue) -> String {
    match v {
        PropertyValue::Text(s) => s.clone(),
        PropertyValue::Selection(Some(s)) => s.clone(),
        PropertyValue::Number(n) => n.to_string(),
        PropertyValue::Date(d) => d.clone(),
        PropertyValue::Checkbox(b) => b.to_string(),
        _ => String::new(),
    }
}

fn apply_filter(entry: &Entry, filter: &Filter) -> bool {
    let value = entry
        .values
        .get(&filter.property_id)
        .unwrap_or(&PropertyValue::Empty);
    match &filter.condition {
        FilterCondition::IsEmpty => matches!(value, PropertyValue::Empty),
        FilterCondition::IsFilled => !matches!(value, PropertyValue::Empty),
        FilterCondition::Equal(v) => value == v,
        FilterCondition::Contains(s) => match value {
            PropertyValue::Text(t) => t.contains(s.as_str()),
            PropertyValue::Url(u) => u.contains(s.as_str()),
            PropertyValue::Title(inlines) => {
                inlines.iter().any(|i| i.content.contains(s.as_str()))
            }
            _ => false,
        },
    }
}

fn compare_values(a: &PropertyValue, b: &PropertyValue) -> Ordering {
    match (a, b) {
        (PropertyValue::Number(x), PropertyValue::Number(y)) => {
            x.partial_cmp(y).unwrap_or(Ordering::Equal)
        }
        (PropertyValue::Text(x), PropertyValue::Text(y)) => x.cmp(y),
        (PropertyValue::Date(x), PropertyValue::Date(y)) => x.cmp(y),
        (PropertyValue::Checkbox(x), PropertyValue::Checkbox(y)) => x.cmp(y),
        (PropertyValue::Empty, PropertyValue::Empty) => Ordering::Equal,
        (PropertyValue::Empty, _) => Ordering::Greater,
        (_, PropertyValue::Empty) => Ordering::Less,
        _ => Ordering::Equal,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::database::{ViewType, View};
    use crate::domain::document::InlineText;
    use std::cell::RefCell;

    struct MockDbRepo {
        dbs: RefCell<std::collections::HashMap<Uuid, Database>>,
    }

    impl MockDbRepo {
        fn new() -> Self {
            Self {
                dbs: RefCell::new(std::collections::HashMap::new()),
            }
        }
    }

    impl DatabaseRepository for MockDbRepo {
        fn save(&self, db: &Database) -> Result<(), PinkhaError> {
            self.dbs.borrow_mut().insert(db.id, db.clone());
            Ok(())
        }
        fn load(&self, id: Uuid) -> Result<Database, PinkhaError> {
            self.dbs
                .borrow()
                .get(&id)
                .cloned()
                .ok_or(PinkhaError::NotFound(id))
        }
        fn list_meta(&self) -> Result<Vec<crate::domain::database::DatabaseMeta>, PinkhaError> {
            Ok(self.dbs.borrow().values().map(|db| db.meta()).collect())
        }
        fn delete(&self, id: Uuid) -> Result<(), PinkhaError> {
            self.dbs
                .borrow_mut()
                .remove(&id)
                .map(|_| ())
                .ok_or(PinkhaError::NotFound(id))
        }
    }

    fn title(s: &str) -> Vec<InlineText> {
        vec![InlineText {
            content: s.to_string(),
            styles: vec![],
        }]
    }

    #[test]
    fn test_rename_property() {
        let repo = MockDbRepo::new();
        let prop = Property::new("Ancien", PropertyType::Text);
        let prop_id = prop.id;
        let db = Database::new(title("DB"), vec![prop]);
        repo.save(&db).unwrap();

        rename_property(&repo, db.id, prop_id, "Nouveau").unwrap();

        let db = repo.load(db.id).unwrap();
        assert_eq!(db.properties[0].name, "Nouveau");
    }

    #[test]
    fn test_rename_property_inexistante_erreur() {
        let repo = MockDbRepo::new();
        let db = Database::new(title("DB"), vec![]);
        repo.save(&db).unwrap();

        let res = rename_property(&repo, db.id, Uuid::new_v4(), "X");
        assert!(matches!(res, Err(PinkhaError::NotFound(_))));
    }

    #[test]
    fn test_delete_property_retire_des_entries() {
        let repo = MockDbRepo::new();
        let prop = Property::new("Statut", PropertyType::Text);
        let prop_id = prop.id;
        let mut db = Database::new(title("DB"), vec![prop]);
        let mut values = HashMap::new();
        values.insert(prop_id, PropertyValue::Text("En cours".to_string()));
        db.entries.push(Entry::new(values));
        repo.save(&db).unwrap();

        delete_property(&repo, db.id, prop_id).unwrap();

        let db = repo.load(db.id).unwrap();
        assert!(db.properties.is_empty());
        assert!(!db.entries[0].values.contains_key(&prop_id));
    }

    #[test]
    fn test_delete_property_inexistante_erreur() {
        let repo = MockDbRepo::new();
        let db = Database::new(title("DB"), vec![]);
        repo.save(&db).unwrap();

        let res = delete_property(&repo, db.id, Uuid::new_v4());
        assert!(matches!(res, Err(PinkhaError::NotFound(_))));
    }

    #[test]
    fn test_update_view_met_a_jour_filters_et_sorts() {
        let repo = MockDbRepo::new();
        let prop = Property::new("Note", PropertyType::Number);
        let prop_id = prop.id;
        let db = Database::new(title("DB"), vec![prop]);
        let view_id = db.views[0].id;
        repo.save(&db).unwrap();

        let filter = Filter {
            property_id: prop_id,
            condition: FilterCondition::IsFilled,
        };
        let sort = Sort::by_property(prop_id, Order::Descending);
        update_view(&repo, db.id, view_id, vec![filter], vec![sort]).unwrap();

        let db = repo.load(db.id).unwrap();
        assert_eq!(db.views[0].filters.len(), 1);
        assert_eq!(db.views[0].sorts.len(), 1);
    }

    #[test]
    fn test_delete_view() {
        let repo = MockDbRepo::new();
        let mut db = Database::new(title("DB"), vec![]);
        let view2 = View::new("Kanban", ViewType::Gallery);
        let view2_id = view2.id;
        db.views.push(view2);
        repo.save(&db).unwrap();

        delete_view(&repo, db.id, view2_id).unwrap();

        let db = repo.load(db.id).unwrap();
        assert_eq!(db.views.len(), 1);
        assert!(db.views.iter().all(|v| v.id != view2_id));
    }

    #[test]
    fn test_supprimer_derniere_vue_erreur() {
        let repo = MockDbRepo::new();
        let db = Database::new(title("DB"), vec![]);
        let view_id = db.views[0].id;
        repo.save(&db).unwrap();

        let res = delete_view(&repo, db.id, view_id);
        assert!(matches!(res, Err(PinkhaError::InvalidOperation(_))));
    }

    #[test]
    fn test_delete_view_inexistante_erreur() {
        let repo = MockDbRepo::new();
        let mut db = Database::new(title("DB"), vec![]);
        db.views.push(View::new("Extra", ViewType::Gallery));
        repo.save(&db).unwrap();

        let res = delete_view(&repo, db.id, Uuid::new_v4());
        assert!(matches!(res, Err(PinkhaError::NotFound(_))));
    }

    fn entry_with_number(prop_id: Uuid, n: f64) -> Entry {
        let mut map = HashMap::new();
        map.insert(prop_id, PropertyValue::Number(n));
        Entry::new(map)
    }

    fn entry_with_text(prop_id: Uuid, s: &str) -> Entry {
        let mut map = HashMap::new();
        map.insert(prop_id, PropertyValue::Text(s.to_string()));
        Entry::new(map)
    }

    #[test]
    fn test_filtre_est_vide() {
        let prop_id = Uuid::new_v4();
        let entry = Entry::new(HashMap::new());
        let filter = Filter {
            property_id: prop_id,
            condition: FilterCondition::IsEmpty,
        };
        assert!(apply_filter(&entry, &filter));
    }

    #[test]
    fn test_filtre_est_plein() {
        let prop_id = Uuid::new_v4();
        let entry = entry_with_text(prop_id, "valeur");
        let filter = Filter {
            property_id: prop_id,
            condition: FilterCondition::IsFilled,
        };
        assert!(apply_filter(&entry, &filter));
    }

    #[test]
    fn test_filtre_contient() {
        let prop_id = Uuid::new_v4();
        let entry = entry_with_text(prop_id, "Bonjour monde");
        let filter = Filter {
            property_id: prop_id,
            condition: FilterCondition::Contains("monde".to_string()),
        };
        assert!(apply_filter(&entry, &filter));
    }

    #[test]
    fn test_filtre_egal_nombre() {
        let prop_id = Uuid::new_v4();
        let entry = entry_with_number(prop_id, 42.0);
        let filter = Filter {
            property_id: prop_id,
            condition: FilterCondition::Equal(PropertyValue::Number(42.0)),
        };
        assert!(apply_filter(&entry, &filter));
    }

    #[test]
    fn test_comparer_nombres() {
        let a = PropertyValue::Number(1.0);
        let b = PropertyValue::Number(2.0);
        assert_eq!(compare_values(&a, &b), Ordering::Less);
    }

    #[test]
    fn test_vide_en_dernier() {
        let a = PropertyValue::Empty;
        let b = PropertyValue::Number(0.0);
        assert_eq!(compare_values(&a, &b), Ordering::Greater);
    }

    #[test]
    fn test_calculer_aggregate_somme() {
        let prop_id = Uuid::new_v4();
        let entries = vec![
            entry_with_number(prop_id, 10.0),
            entry_with_number(prop_id, 20.0),
            entry_with_number(prop_id, 30.0),
        ];
        let refs: Vec<&Entry> = entries.iter().collect();
        assert_eq!(
            calculate_aggregate(&refs, prop_id, &Aggregate::Sum),
            PropertyValue::Number(60.0)
        );
    }

    #[test]
    fn test_calculer_aggregate_compter() {
        let prop_id = Uuid::new_v4();
        let e1 = entry_with_number(prop_id, 1.0);
        let e2 = entry_with_number(prop_id, 2.0);
        let refs: Vec<&Entry> = vec![&e1, &e2];
        assert_eq!(
            calculate_aggregate(&refs, prop_id, &Aggregate::Count),
            PropertyValue::Number(2.0)
        );
    }

    #[test]
    fn test_calculer_aggregate_moyenne() {
        let prop_id = Uuid::new_v4();
        let entries = vec![
            entry_with_number(prop_id, 10.0),
            entry_with_number(prop_id, 20.0),
        ];
        let refs: Vec<&Entry> = entries.iter().collect();
        assert_eq!(
            calculate_aggregate(&refs, prop_id, &Aggregate::Average),
            PropertyValue::Number(15.0)
        );
    }

    #[test]
    fn test_group_key_texte() {
        assert_eq!(group_key(&PropertyValue::Text("A".to_string())), "A");
        assert_eq!(group_key(&PropertyValue::Empty), String::new());
    }

    #[test]
    fn test_value_contains_texte() {
        assert!(value_contains(
            &PropertyValue::Text("Bonjour monde".to_string()),
            "monde"
        ));
        assert!(!value_contains(
            &PropertyValue::Text("Bonjour".to_string()),
            "monde"
        ));
    }

    #[test]
    fn test_value_contains_insensible_casse() {
        assert!(value_contains(
            &PropertyValue::Text("Journal".to_string()),
            "journal"
        ));
    }

    #[test]
    fn test_value_contains_vide_ne_match_pas() {
        assert!(!value_contains(&PropertyValue::Empty, "anything"));
        assert!(!value_contains(&PropertyValue::Number(42.0), "42"));
    }
}
