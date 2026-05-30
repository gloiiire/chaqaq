use crate::application::database_repository::DatabaseRepository;
use crate::application::error::ChaqaqError;
use crate::domain::database::{
    Aggregate, FilterCondition, Database, DatabaseMeta, Entry, Filter, Group, Order, Property,
    PropertyType, SortSource, Sort, PropertyValue, View,
};
use crate::domain::document::InlineText;
use std::cmp::Ordering;
use std::collections::HashMap;
use uuid::Uuid;

pub fn create_database(
    repo: &dyn DatabaseRepository,
    title: Vec<InlineText>,
    properties: Vec<Property>,
) -> Result<Database, ChaqaqError> {
    let db = Database::new(title, properties);
    repo.save(&db)?;
    Ok(db)
}

pub fn get_database(repo: &dyn DatabaseRepository, id: Uuid) -> Result<Database, ChaqaqError> {
    repo.load(id)
}

pub fn list_databases(repo: &dyn DatabaseRepository) -> Result<Vec<DatabaseMeta>, ChaqaqError> {
    repo.list_meta()
}

pub fn delete_database(repo: &dyn DatabaseRepository, db_id: Uuid) -> Result<(), ChaqaqError> {
    repo.delete(db_id)
}

pub fn add_entry(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    values: HashMap<Uuid, PropertyValue>,
) -> Result<Entry, ChaqaqError> {
    let mut db = repo.load(db_id)?;
    let entry = Entry::new(values);
    db.entries.push(entry.clone());
    repo.save(&db)?;
    Ok(entry)
}

pub fn update_entry(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    entry_id: Uuid,
    values: HashMap<Uuid, PropertyValue>,
) -> Result<(), ChaqaqError> {
    let mut db = repo.load(db_id)?;
    let entry = db
        .entries
        .iter_mut()
        .find(|e| e.id == entry_id)
        .ok_or(ChaqaqError::NotFound(entry_id))?;
    entry.values = values;
    repo.save(&db)
}

pub fn delete_entry(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    entry_id: Uuid,
) -> Result<(), ChaqaqError> {
    let mut db = repo.load(db_id)?;
    let avant = db.entries.len();
    db.entries.retain(|e| e.id != entry_id);
    if db.entries.len() == avant {
        return Err(ChaqaqError::NotFound(entry_id));
    }
    repo.save(&db)
}

pub fn add_property(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    propriete: Property,
) -> Result<(), ChaqaqError> {
    let mut db = repo.load(db_id)?;
    db.properties.push(propriete);
    repo.save(&db)
}

pub fn add_view(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    vue: View,
) -> Result<View, ChaqaqError> {
    let mut db = repo.load(db_id)?;
    db.views.push(vue.clone());
    repo.save(&db)?;
    Ok(vue)
}

pub fn requete(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    view_id: Uuid,
) -> Result<Vec<Entry>, ChaqaqError> {
    let db = repo.load(db_id)?;
    let vue = db
        .views
        .iter()
        .find(|v| v.id == view_id)
        .ok_or(ChaqaqError::NotFound(view_id))?;

    let mut entries: Vec<Entry> = db
        .entries
        .iter()
        .filter(|e| vue.filters.iter().all(|f| apply_filter(e, f)))
        .cloned()
        .collect();

    for tri in vue.sorts.iter().rev() {
        entries.sort_by(|a, b| {
            let ord = match &tri.source {
                SortSource::Property => {
                    let va = a
                        .values
                        .get(&tri.property_id)
                        .unwrap_or(&PropertyValue::Empty);
                    let vb = b
                        .values
                        .get(&tri.property_id)
                        .unwrap_or(&PropertyValue::Empty);
                    compare_values(va, vb)
                }
                SortSource::Created => a.created_at.cmp(&b.created_at),
                SortSource::ManualThenCreated => {
                    let va = a
                        .values
                        .get(&tri.property_id)
                        .unwrap_or(&PropertyValue::Empty);
                    let vb = b
                        .values
                        .get(&tri.property_id)
                        .unwrap_or(&PropertyValue::Empty);
                    date_effective(va, &a.created_at).cmp(date_effective(vb, &b.created_at))
                }
            };
            if tri.order == Order::Descending {
                ord.reverse()
            } else {
                ord
            }
        });
    }

    Ok(entries)
}

// ── Propriétés ───────────────────────────────────────────────────────────────

pub fn rename_property(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    prop_id: Uuid,
    new_name: &str,
) -> Result<(), ChaqaqError> {
    let mut db = repo.load(db_id)?;
    let prop = db
        .properties
        .iter_mut()
        .find(|p| p.id == prop_id)
        .ok_or(ChaqaqError::NotFound(prop_id))?;
    prop.name = new_name.to_string();
    repo.save(&db)
}

/// Supprime une propriété et nettoie ses values dans toutes les entrées.
pub fn delete_property(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    prop_id: Uuid,
) -> Result<(), ChaqaqError> {
    let mut db = repo.load(db_id)?;
    let avant = db.properties.len();
    db.properties.retain(|p| p.id != prop_id);
    if db.properties.len() == avant {
        return Err(ChaqaqError::NotFound(prop_id));
    }
    for entry in &mut db.entries {
        entry.values.remove(&prop_id);
    }
    repo.save(&db)
}

// ── Views ─────────────────────────────────────────────────────────────────────

/// Met à jour les filters et sorts d'une vue existante.
pub fn update_view(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    view_id: Uuid,
    filters: Vec<Filter>,
    sorts: Vec<Sort>,
) -> Result<(), ChaqaqError> {
    let mut db = repo.load(db_id)?;
    let vue = db
        .views
        .iter_mut()
        .find(|v| v.id == view_id)
        .ok_or(ChaqaqError::NotFound(view_id))?;
    vue.filters = filters;
    vue.sorts = sorts;
    repo.save(&db)
}

/// Supprime une vue. Retourne InvalidOperation si c'est la dernière.
pub fn delete_view(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    view_id: Uuid,
) -> Result<(), ChaqaqError> {
    let mut db = repo.load(db_id)?;
    if db.views.len() <= 1 {
        return Err(ChaqaqError::InvalidOperation(
            "impossible de supprimer la dernière vue".to_string(),
        ));
    }
    let avant = db.views.len();
    db.views.retain(|v| v.id != view_id);
    if db.views.len() == avant {
        return Err(ChaqaqError::NotFound(view_id));
    }
    repo.save(&db)
}

// ── Recherche ────────────────────────────────────────────────────────────────

/// Recherche insensible à la casse dans toutes les values textuelles des entrées.
pub fn search_entries(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    query: &str,
) -> Result<Vec<Entry>, ChaqaqError> {
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

// ── Relations, Rollups, Agrégats, Groupment ─────────────────────────────────

/// Enrichit les entrées avec les values calculées des colonnes Rollup.
/// Les values rollup ne sont pas persistées — calculées à la lecture.
pub fn evaluate_rollups(
    repo: &dyn DatabaseRepository,
    db: &Database,
    mut entries: Vec<Entry>,
) -> Result<Vec<Entry>, ChaqaqError> {
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
        let db_liee_id = db
            .properties
            .iter()
            .find(|p| p.id == relation_prop_id)
            .and_then(|p| match &p.type_ {
                PropertyType::Relation { db_id } => Some(*db_id),
                _ => None,
            })
            .ok_or(ChaqaqError::NotFound(relation_prop_id))?;

        let db_liee = repo.load(db_liee_id)?;

        for entry in &mut entries {
            let ids_lies = match entry.values.get(&relation_prop_id) {
                Some(PropertyValue::Relation(ids)) => ids.clone(),
                _ => vec![],
            };
            let liees: Vec<&Entry> = db_liee
                .entries
                .iter()
                .filter(|e| ids_lies.contains(&e.id))
                .collect();
            entry
                .values
                .insert(rollup_id, calculer_aggregate(&liees, target_prop_id, &aggregate));
        }
    }

    Ok(entries)
}

/// Requête filtrée + triée + rollups calculés.
pub fn query_with_rollups(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    view_id: Uuid,
) -> Result<Vec<Entry>, ChaqaqError> {
    let db = repo.load(db_id)?;
    let entries = requete(repo, db_id, view_id)?;
    evaluate_rollups(repo, &db, entries)
}

/// Agrège toutes les values d'une colonne numérique sur l'ensemble des entrées.
pub fn column_aggregate(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    prop_id: Uuid,
    aggregate: Aggregate,
) -> Result<PropertyValue, ChaqaqError> {
    let db = repo.load(db_id)?;
    let refs: Vec<&Entry> = db.entries.iter().collect();
    Ok(calculer_aggregate(&refs, prop_id, &aggregate))
}

/// Regroupe les entrées d'une vue par valeur d'une propriété.
pub fn grouped_query(
    repo: &dyn DatabaseRepository,
    db_id: Uuid,
    view_id: Uuid,
    group_by: Uuid,
) -> Result<Vec<Group>, ChaqaqError> {
    let entries = requete(repo, db_id, view_id)?;
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

// ── Helpers internes ─────────────────────────────────────────────────────────

/// Retourne la date effective : valeur manuelle si renseignée, sinon `created_at`.
fn date_effective<'a>(v: &'a PropertyValue, created_at: &'a str) -> &'a str {
    match v {
        PropertyValue::Date(d) if !d.is_empty() => d.as_str(),
        _ => created_at,
    }
}

fn calculer_aggregate(entries: &[&Entry], prop_id: Uuid, aggregate: &Aggregate) -> PropertyValue {
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

fn apply_filter(entry: &Entry, filtre: &Filter) -> bool {
    let value = entry
        .values
        .get(&filtre.property_id)
        .unwrap_or(&PropertyValue::Empty);
    match &filtre.condition {
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
        fn nouveau() -> Self {
            Self {
                dbs: RefCell::new(std::collections::HashMap::new()),
            }
        }
    }

    impl DatabaseRepository for MockDbRepo {
        fn save(&self, db: &Database) -> Result<(), ChaqaqError> {
            self.dbs.borrow_mut().insert(db.id, db.clone());
            Ok(())
        }
        fn load(&self, id: Uuid) -> Result<Database, ChaqaqError> {
            self.dbs
                .borrow()
                .get(&id)
                .cloned()
                .ok_or(ChaqaqError::NotFound(id))
        }
        fn list_meta(&self) -> Result<Vec<crate::domain::database::DatabaseMeta>, ChaqaqError> {
            Ok(self.dbs.borrow().values().map(|db| db.meta()).collect())
        }
        fn delete(&self, id: Uuid) -> Result<(), ChaqaqError> {
            self.dbs
                .borrow_mut()
                .remove(&id)
                .map(|_| ())
                .ok_or(ChaqaqError::NotFound(id))
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
        let repo = MockDbRepo::nouveau();
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
        let repo = MockDbRepo::nouveau();
        let db = Database::new(title("DB"), vec![]);
        repo.save(&db).unwrap();

        let res = rename_property(&repo, db.id, Uuid::new_v4(), "X");
        assert!(matches!(res, Err(ChaqaqError::NotFound(_))));
    }

    #[test]
    fn test_delete_property_retire_des_entries() {
        let repo = MockDbRepo::nouveau();
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
        let repo = MockDbRepo::nouveau();
        let db = Database::new(title("DB"), vec![]);
        repo.save(&db).unwrap();

        let res = delete_property(&repo, db.id, Uuid::new_v4());
        assert!(matches!(res, Err(ChaqaqError::NotFound(_))));
    }

    #[test]
    fn test_update_view_met_a_jour_filters_et_sorts() {
        let repo = MockDbRepo::nouveau();
        let prop = Property::new("Note", PropertyType::Number);
        let prop_id = prop.id;
        let db = Database::new(title("DB"), vec![prop]);
        let view_id = db.views[0].id;
        repo.save(&db).unwrap();

        let filtre = Filter {
            property_id: prop_id,
            condition: FilterCondition::IsFilled,
        };
        let tri = Sort::by_property(prop_id, Order::Descending);
        update_view(&repo, db.id, view_id, vec![filtre], vec![tri]).unwrap();

        let db = repo.load(db.id).unwrap();
        assert_eq!(db.views[0].filters.len(), 1);
        assert_eq!(db.views[0].sorts.len(), 1);
    }

    #[test]
    fn test_delete_view() {
        let repo = MockDbRepo::nouveau();
        let mut db = Database::new(title("DB"), vec![]);
        let vue2 = View::new("Kanban", ViewType::Gallery);
        let vue2_id = vue2.id;
        db.views.push(vue2);
        repo.save(&db).unwrap();

        delete_view(&repo, db.id, vue2_id).unwrap();

        let db = repo.load(db.id).unwrap();
        assert_eq!(db.views.len(), 1);
        assert!(db.views.iter().all(|v| v.id != vue2_id));
    }

    #[test]
    fn test_supprimer_derniere_vue_erreur() {
        let repo = MockDbRepo::nouveau();
        let db = Database::new(title("DB"), vec![]);
        let view_id = db.views[0].id;
        repo.save(&db).unwrap();

        let res = delete_view(&repo, db.id, view_id);
        assert!(matches!(res, Err(ChaqaqError::InvalidOperation(_))));
    }

    #[test]
    fn test_delete_view_inexistante_erreur() {
        let repo = MockDbRepo::nouveau();
        let mut db = Database::new(title("DB"), vec![]);
        db.views.push(View::new("Extra", ViewType::Gallery));
        repo.save(&db).unwrap();

        let res = delete_view(&repo, db.id, Uuid::new_v4());
        assert!(matches!(res, Err(ChaqaqError::NotFound(_))));
    }

    fn entry_avec_nombre(prop_id: Uuid, n: f64) -> Entry {
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
        let filtre = Filter {
            property_id: prop_id,
            condition: FilterCondition::IsEmpty,
        };
        assert!(apply_filter(&entry, &filtre));
    }

    #[test]
    fn test_filtre_est_plein() {
        let prop_id = Uuid::new_v4();
        let entry = entry_with_text(prop_id, "valeur");
        let filtre = Filter {
            property_id: prop_id,
            condition: FilterCondition::IsFilled,
        };
        assert!(apply_filter(&entry, &filtre));
    }

    #[test]
    fn test_filtre_contient() {
        let prop_id = Uuid::new_v4();
        let entry = entry_with_text(prop_id, "Bonjour monde");
        let filtre = Filter {
            property_id: prop_id,
            condition: FilterCondition::Contains("monde".to_string()),
        };
        assert!(apply_filter(&entry, &filtre));
    }

    #[test]
    fn test_filtre_egal_nombre() {
        let prop_id = Uuid::new_v4();
        let entry = entry_avec_nombre(prop_id, 42.0);
        let filtre = Filter {
            property_id: prop_id,
            condition: FilterCondition::Equal(PropertyValue::Number(42.0)),
        };
        assert!(apply_filter(&entry, &filtre));
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
            entry_avec_nombre(prop_id, 10.0),
            entry_avec_nombre(prop_id, 20.0),
            entry_avec_nombre(prop_id, 30.0),
        ];
        let refs: Vec<&Entry> = entries.iter().collect();
        assert_eq!(
            calculer_aggregate(&refs, prop_id, &Aggregate::Sum),
            PropertyValue::Number(60.0)
        );
    }

    #[test]
    fn test_calculer_aggregate_compter() {
        let prop_id = Uuid::new_v4();
        let e1 = entry_avec_nombre(prop_id, 1.0);
        let e2 = entry_avec_nombre(prop_id, 2.0);
        let refs: Vec<&Entry> = vec![&e1, &e2];
        assert_eq!(
            calculer_aggregate(&refs, prop_id, &Aggregate::Count),
            PropertyValue::Number(2.0)
        );
    }

    #[test]
    fn test_calculer_aggregate_moyenne() {
        let prop_id = Uuid::new_v4();
        let entries = vec![
            entry_avec_nombre(prop_id, 10.0),
            entry_avec_nombre(prop_id, 20.0),
        ];
        let refs: Vec<&Entry> = entries.iter().collect();
        assert_eq!(
            calculer_aggregate(&refs, prop_id, &Aggregate::Average),
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
