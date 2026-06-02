use crate::application::error::PinkhaError;
use crate::application::unit_of_work::UnitOfWork;
use crate::domain::database::{
    Entry, Filter, FilterCondition, Group, Order, PropertyValue, SortSource,
};
use std::cmp::Ordering;
use std::collections::HashMap;
use uuid::Uuid;

/// Returns the entries visible in a view after applying its filters and sorts.
pub fn query(uow: &dyn UnitOfWork, db_id: Uuid, view_id: Uuid) -> Result<Vec<Entry>, PinkhaError> {
    let db = uow.databases().load(db_id)?;
    let view = db
        .views
        .iter()
        .find(|v| v.id == view_id)
        .ok_or(PinkhaError::NotFound(view_id))?;

    let mut entries: Vec<Entry> = db
        .entries
        .iter()
        .filter(|e| !e.is_deleted())
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

/// Runs `query` then enriches the result with computed Rollup values.
pub fn query_with_rollups(
    uow: &dyn UnitOfWork,
    db_id: Uuid,
    view_id: Uuid,
) -> Result<Vec<Entry>, PinkhaError> {
    let db = uow.databases().load(db_id)?;
    let entries = query(uow, db_id, view_id)?;
    crate::application::database_use_cases::evaluate_rollups(uow, &db, entries)
}

/// Aggregates all values of a numeric column across every entry in the database.
pub fn column_aggregate(
    uow: &dyn UnitOfWork,
    db_id: Uuid,
    prop_id: Uuid,
    aggregate: crate::domain::database::Aggregate,
) -> Result<PropertyValue, PinkhaError> {
    let db = uow.databases().load(db_id)?;
    let refs: Vec<&Entry> = db.entries.iter().filter(|e| !e.is_deleted()).collect();
    Ok(calculate_aggregate(&refs, prop_id, &aggregate))
}

/// Groups the entries of a view by the value of a given property.
pub fn grouped_query(
    uow: &dyn UnitOfWork,
    db_id: Uuid,
    view_id: Uuid,
    group_by: Uuid,
) -> Result<Vec<Group>, PinkhaError> {
    let entries = query(uow, db_id, view_id)?;
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
pub(super) fn effective_date<'a>(v: &'a PropertyValue, created_at: &'a str) -> &'a str {
    match v {
        PropertyValue::Date(d) if !d.is_empty() => d.as_str(),
        _ => created_at,
    }
}

pub(super) fn calculate_aggregate(
    entries: &[&Entry],
    prop_id: Uuid,
    aggregate: &crate::domain::database::Aggregate,
) -> PropertyValue {
    use crate::domain::database::Aggregate;
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
        Aggregate::Min => {
            return if nums.is_empty() {
                PropertyValue::Empty
            } else {
                PropertyValue::Number(nums.iter().cloned().fold(f64::INFINITY, f64::min))
            };
        }
        Aggregate::Max => {
            return if nums.is_empty() {
                PropertyValue::Empty
            } else {
                PropertyValue::Number(nums.iter().cloned().fold(f64::NEG_INFINITY, f64::max))
            };
        }
    };
    PropertyValue::Number(r)
}

pub(super) fn group_key(v: &PropertyValue) -> String {
    match v {
        PropertyValue::Text(s) => s.clone(),
        PropertyValue::Selection(Some(s)) => s.clone(),
        PropertyValue::Number(n) => n.to_string(),
        PropertyValue::Date(d) => d.clone(),
        PropertyValue::Checkbox(b) => b.to_string(),
        _ => String::new(),
    }
}

pub(super) fn apply_filter(entry: &Entry, filter: &Filter) -> bool {
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
            PropertyValue::Title(inlines) => inlines.iter().any(|i| i.content.contains(s.as_str())),
            _ => false,
        },
    }
}

pub(super) fn compare_values(a: &PropertyValue, b: &PropertyValue) -> Ordering {
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
    use std::collections::HashMap;
    use uuid::Uuid;

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
        use crate::domain::database::Aggregate;
        let prop_id = Uuid::new_v4();
        let entries = [
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
        use crate::domain::database::Aggregate;
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
        use crate::domain::database::Aggregate;
        let prop_id = Uuid::new_v4();
        let entries = [
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
}
