use crate::application::error::PinkhaError;
use crate::application::unit_of_work::UnitOfWork;
use crate::domain::book::{
    Book, DateGranularity, DateGrouping, DateGroupingSource, Entry, Filter, FilterCondition, Group,
    Order, PropertyValue, SortSource,
};
use std::cmp::Ordering;
use std::collections::HashMap;
use uuid::Uuid;

/// Returns the entries visible in a view after applying its filters and sorts.
pub fn query(
    uow: &dyn UnitOfWork,
    book_id: Uuid,
    view_id: Uuid,
) -> Result<Vec<Entry>, PinkhaError> {
    let db = uow.books().load(book_id)?;
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
                SortSource::Published => {
                    // Empty `published_at` (legacy entries pre-field)
                    // falls back to `created_at` so they sort alongside
                    // freshly-inserted ones without a jump.
                    let pa = if a.published_at.is_empty() {
                        a.created_at.as_str()
                    } else {
                        a.published_at.as_str()
                    };
                    let pb = if b.published_at.is_empty() {
                        b.created_at.as_str()
                    } else {
                        b.published_at.as_str()
                    };
                    pa.cmp(pb)
                }
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
    book_id: Uuid,
    view_id: Uuid,
) -> Result<Vec<Entry>, PinkhaError> {
    let db = uow.books().load(book_id)?;
    let entries = query(uow, book_id, view_id)?;
    crate::application::book_use_cases::evaluate_rollups(uow, &db, entries)
}

/// Aggregates all values of a numeric column across every entry in the book.
pub fn column_aggregate(
    uow: &dyn UnitOfWork,
    book_id: Uuid,
    prop_id: Uuid,
    aggregate: crate::domain::book::Aggregate,
) -> Result<PropertyValue, PinkhaError> {
    let db = uow.books().load(book_id)?;
    let refs: Vec<&Entry> = db.entries.iter().filter(|e| !e.is_deleted()).collect();
    Ok(calculate_aggregate(&refs, prop_id, &aggregate))
}

/// Groups the entries of a view by the value of a given property.
pub fn grouped_query(
    uow: &dyn UnitOfWork,
    book_id: Uuid,
    view_id: Uuid,
    group_by: Uuid,
) -> Result<Vec<Group>, PinkhaError> {
    let entries = query(uow, book_id, view_id)?;
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

/// A node in the date-grouping tree returned by [`date_grouped_query`].
///
/// Layout depends on the [`DateGranularity`] used :
///
/// | Granularity | Tree shape                                |
/// |-------------|-------------------------------------------|
/// | `Year`      | one level : nodes with `label_year`       |
/// | `Month`     | one level : nodes with `label_year` + `label_month` |
/// | `Day`       | one level : nodes with `year` + `month` + `day` |
/// | `YearMonth` | two levels : year node with month children |
///
/// `label_year == None` denotes the "No date" bucket — entries whose
/// chosen source produced no parseable date. It is rendered separately
/// at the end of the list (UI-side).
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct DateGroupNode {
    /// Calendar year, or `None` for the "No date" bucket.
    pub label_year: Option<i32>,
    /// Month 1-12, when relevant for the granularity.
    pub label_month: Option<u32>,
    /// Day 1-31, only set when granularity is `Day`.
    pub label_day: Option<u32>,
    /// Entries that fall directly into this bucket. Always empty for
    /// the year-level node in `YearMonth` granularity ; the entries
    /// live in the month children instead.
    pub entries: Vec<Entry>,
    /// Sub-buckets, only populated for `YearMonth`.
    pub children: Vec<DateGroupNode>,
}

impl DateGroupNode {
    /// Total entries reachable from this node, including those in
    /// `children` for `YearMonth`. Useful for header count badges.
    pub fn total_entries(&self) -> usize {
        if self.children.is_empty() {
            self.entries.len()
        } else {
            self.children.iter().map(|c| c.total_entries()).sum()
        }
    }
}

/// Partitions a view's entries into chronological buckets, applying
/// the active filters and sorts first.
///
/// The grouping config is read from the view's `date_grouping` field
/// when no explicit override is passed. Callers that want to preview
/// a different config (UI sheet, tests) can pass it via `override_grouping`.
///
/// Returns `Ok(vec![])` when the view has no grouping configured —
/// callers should fall back to their flat rendering path.
pub fn date_grouped_query(
    uow: &dyn UnitOfWork,
    book_id: Uuid,
    view_id: Uuid,
    override_grouping: Option<DateGrouping>,
) -> Result<Vec<DateGroupNode>, PinkhaError> {
    let db = uow.books().load(book_id)?;
    let entries = query(uow, book_id, view_id)?;

    let grouping = match override_grouping {
        Some(g) => g,
        None => {
            let view = db.views.iter().find(|v| v.id == view_id).ok_or_else(|| {
                PinkhaError::InvalidOperation(format!("view {view_id} not found"))
            })?;
            match &view.date_grouping {
                Some(g) => g.clone(),
                None => return Ok(vec![]),
            }
        }
    };

    Ok(build_date_groups(&db, entries, &grouping))
}

fn build_date_groups(db: &Book, entries: Vec<Entry>, g: &DateGrouping) -> Vec<DateGroupNode> {
    // Bucket entries by the (year, month, day) extracted from the
    // configured source. The "no date" bucket gets a `None` key.
    type Key = Option<(i32, u32, u32)>;
    let mut buckets: HashMap<Key, Vec<Entry>> = HashMap::new();
    let mut order: Vec<Key> = Vec::new();

    for entry in entries {
        let key = entry_ymd(&entry, &g.source, db);
        if !buckets.contains_key(&key) {
            order.push(key);
        }
        buckets.entry(key).or_default().push(entry);
    }

    // Build flat or hierarchical structure depending on granularity.
    let mut nodes: Vec<DateGroupNode> = match g.granularity {
        DateGranularity::Year => collapse_by_year(buckets),
        DateGranularity::Month => collapse_by_month(buckets),
        DateGranularity::Day => collapse_by_day(buckets),
        DateGranularity::YearMonth => collapse_by_year_then_month(buckets),
    };

    // Order top-level nodes chronologically. The "No date" bucket
    // (None) always sinks to the bottom regardless of direction.
    sort_nodes_chronologically(&mut nodes, g.ascending);

    // Sub-nodes inherit the same direction so a year that's expanded
    // shows its months in the user's chosen order.
    for node in nodes.iter_mut() {
        if !node.children.is_empty() {
            sort_nodes_chronologically(&mut node.children, g.ascending);
        }
    }

    let _ = order; // insertion-order map kept for potential future use.
    nodes
}

fn collapse_by_year(buckets: HashMap<Option<(i32, u32, u32)>, Vec<Entry>>) -> Vec<DateGroupNode> {
    let mut years: HashMap<Option<i32>, Vec<Entry>> = HashMap::new();
    for (k, mut v) in buckets {
        let year = k.map(|(y, _, _)| y);
        years.entry(year).or_default().append(&mut v);
    }
    years
        .into_iter()
        .map(|(year, entries)| DateGroupNode {
            label_year: year,
            label_month: None,
            label_day: None,
            entries,
            children: vec![],
        })
        .collect()
}

fn collapse_by_month(buckets: HashMap<Option<(i32, u32, u32)>, Vec<Entry>>) -> Vec<DateGroupNode> {
    let mut months: HashMap<Option<(i32, u32)>, Vec<Entry>> = HashMap::new();
    for (k, mut v) in buckets {
        let key = k.map(|(y, m, _)| (y, m));
        months.entry(key).or_default().append(&mut v);
    }
    months
        .into_iter()
        .map(|(key, entries)| DateGroupNode {
            label_year: key.map(|(y, _)| y),
            label_month: key.map(|(_, m)| m),
            label_day: None,
            entries,
            children: vec![],
        })
        .collect()
}

fn collapse_by_day(buckets: HashMap<Option<(i32, u32, u32)>, Vec<Entry>>) -> Vec<DateGroupNode> {
    buckets
        .into_iter()
        .map(|(key, entries)| DateGroupNode {
            label_year: key.map(|(y, _, _)| y),
            label_month: key.map(|(_, m, _)| m),
            label_day: key.map(|(_, _, d)| d),
            entries,
            children: vec![],
        })
        .collect()
}

fn collapse_by_year_then_month(
    buckets: HashMap<Option<(i32, u32, u32)>, Vec<Entry>>,
) -> Vec<DateGroupNode> {
    // year -> month -> entries
    let mut year_map: HashMap<Option<i32>, HashMap<Option<u32>, Vec<Entry>>> = HashMap::new();
    for (k, mut v) in buckets {
        let year = k.map(|(y, _, _)| y);
        let month = k.map(|(_, m, _)| m);
        year_map
            .entry(year)
            .or_default()
            .entry(month)
            .or_default()
            .append(&mut v);
    }

    year_map
        .into_iter()
        .map(|(year, months)| {
            let mut children: Vec<DateGroupNode> = months
                .into_iter()
                .map(|(month, entries)| DateGroupNode {
                    label_year: year,
                    label_month: month,
                    label_day: None,
                    entries,
                    children: vec![],
                })
                .collect();
            // Stable inner sort here — outer sort handled by caller.
            children.sort_by_key(|c| c.label_month);
            DateGroupNode {
                label_year: year,
                label_month: None,
                label_day: None,
                entries: vec![],
                children,
            }
        })
        .collect()
}

fn sort_nodes_chronologically(nodes: &mut [DateGroupNode], ascending: bool) {
    nodes.sort_by(|a, b| {
        // "No date" (year = None) always sinks to the bottom.
        match (a.label_year, b.label_year) {
            (None, None) => Ordering::Equal,
            (None, _) => Ordering::Greater,
            (_, None) => Ordering::Less,
            (Some(ya), Some(yb)) => {
                let primary = ya.cmp(&yb);
                let secondary = a.label_month.cmp(&b.label_month);
                let tertiary = a.label_day.cmp(&b.label_day);
                let ord = primary.then(secondary).then(tertiary);
                if ascending { ord } else { ord.reverse() }
            }
        }
    });
}

/// Resolves the (year, month, day) of an entry under a given source.
/// `None` means the cell is missing, empty, or fails to parse.
fn entry_ymd(entry: &Entry, source: &DateGroupingSource, db: &Book) -> Option<(i32, u32, u32)> {
    let raw = match source {
        DateGroupingSource::Created => entry.created_at.as_str(),
        DateGroupingSource::Published => {
            if entry.published_at.is_empty() {
                entry.created_at.as_str()
            } else {
                entry.published_at.as_str()
            }
        }
        DateGroupingSource::Property(prop_id) => {
            // Validate the property still exists ; fall back to "no
            // date" rather than created_at so a deleted column doesn't
            // silently lump every entry into "today".
            db.properties.iter().find(|p| p.id == *prop_id)?;
            match entry.values.get(prop_id) {
                Some(PropertyValue::Date(s)) if !s.is_empty() => s.as_str(),
                _ => return None,
            }
        }
    };
    parse_ymd(raw)
}

/// Tolerant date parser matching the Swift `parsePinkhaDate` shape :
/// accepts RFC 3339 with or without fractional seconds and bare
/// `YYYY-MM-DD`. We avoid pulling chrono's parser in here because the
/// three legal shapes can be extracted via plain string slicing.
fn parse_ymd(s: &str) -> Option<(i32, u32, u32)> {
    if s.len() < 10 {
        return None;
    }
    let (y, rest) = s.split_at(4);
    let year: i32 = y.parse().ok()?;
    let bytes = rest.as_bytes();
    if bytes.first()? != &b'-' {
        return None;
    }
    let month: u32 = rest.get(1..3)?.parse().ok()?;
    if bytes.get(3)? != &b'-' {
        return None;
    }
    let day: u32 = rest.get(4..6)?.parse().ok()?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    Some((year, month, day))
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
    aggregate: &crate::domain::book::Aggregate,
) -> PropertyValue {
    use crate::domain::book::Aggregate;
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
        use crate::domain::book::Aggregate;
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
        use crate::domain::book::Aggregate;
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
        use crate::domain::book::Aggregate;
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

    // ── Date grouping ────────────────────────────────────────────────────

    #[test]
    fn parse_ymd_handles_rfc3339_and_bare_date() {
        assert_eq!(parse_ymd("2024-01-15T10:30:45.123Z"), Some((2024, 1, 15)));
        assert_eq!(parse_ymd("2024-01-15T10:30:45Z"), Some((2024, 1, 15)));
        assert_eq!(parse_ymd("2024-01-15"), Some((2024, 1, 15)));
        assert_eq!(parse_ymd(""), None);
        assert_eq!(parse_ymd("not a date"), None);
        assert_eq!(parse_ymd("2024-13-15"), None);
    }

    fn entry_with_date(prop_id: Uuid, date: &str) -> Entry {
        let mut map = HashMap::new();
        map.insert(prop_id, PropertyValue::Date(date.to_string()));
        Entry::new(map)
    }

    fn make_book_with_date_prop(prop_id: Uuid) -> Book {
        use crate::domain::book::{Property, PropertyType};
        let mut prop = Property::new("When", PropertyType::Date);
        prop.id = prop_id;
        Book::new(vec![], vec![prop])
    }

    #[test]
    fn build_date_groups_year_buckets_by_year() {
        let prop = Uuid::new_v4();
        let db = make_book_with_date_prop(prop);
        let entries = vec![
            entry_with_date(prop, "2024-01-15"),
            entry_with_date(prop, "2024-08-02"),
            entry_with_date(prop, "2023-12-01"),
        ];
        let g = DateGrouping {
            source: DateGroupingSource::Property(prop),
            granularity: DateGranularity::Year,
            ascending: false,
        };
        let nodes = build_date_groups(&db, entries, &g);
        assert_eq!(nodes.len(), 2);
        assert_eq!(nodes[0].label_year, Some(2024)); // newest first
        assert_eq!(nodes[0].entries.len(), 2);
        assert_eq!(nodes[1].label_year, Some(2023));
        assert_eq!(nodes[1].entries.len(), 1);
    }

    #[test]
    fn build_date_groups_ascending_flips_order() {
        let prop = Uuid::new_v4();
        let db = make_book_with_date_prop(prop);
        let entries = vec![
            entry_with_date(prop, "2024-01-15"),
            entry_with_date(prop, "2023-12-01"),
        ];
        let g = DateGrouping {
            source: DateGroupingSource::Property(prop),
            granularity: DateGranularity::Year,
            ascending: true,
        };
        let nodes = build_date_groups(&db, entries, &g);
        assert_eq!(nodes[0].label_year, Some(2023));
        assert_eq!(nodes[1].label_year, Some(2024));
    }

    #[test]
    fn build_date_groups_year_month_nests_months_under_year() {
        let prop = Uuid::new_v4();
        let db = make_book_with_date_prop(prop);
        let entries = vec![
            entry_with_date(prop, "2024-01-15"),
            entry_with_date(prop, "2024-01-20"),
            entry_with_date(prop, "2024-03-01"),
            entry_with_date(prop, "2023-12-01"),
        ];
        let g = DateGrouping {
            source: DateGroupingSource::Property(prop),
            granularity: DateGranularity::YearMonth,
            ascending: false,
        };
        let nodes = build_date_groups(&db, entries, &g);
        assert_eq!(nodes.len(), 2);
        let y2024 = &nodes[0];
        assert_eq!(y2024.label_year, Some(2024));
        assert!(
            y2024.entries.is_empty(),
            "year nodes carry children, not entries"
        );
        assert_eq!(y2024.children.len(), 2);
        // Newest month first inside the year (March 3 > January 1).
        assert_eq!(y2024.children[0].label_month, Some(3));
        assert_eq!(y2024.children[1].label_month, Some(1));
        assert_eq!(y2024.children[1].entries.len(), 2);
    }

    #[test]
    fn build_date_groups_missing_date_goes_to_no_date_bucket_last() {
        let prop = Uuid::new_v4();
        let db = make_book_with_date_prop(prop);
        let undated = Entry::new(HashMap::new());
        let entries = vec![entry_with_date(prop, "2024-01-15"), undated];
        let g = DateGrouping {
            source: DateGroupingSource::Property(prop),
            granularity: DateGranularity::Year,
            ascending: false,
        };
        let nodes = build_date_groups(&db, entries, &g);
        assert_eq!(nodes.len(), 2);
        assert_eq!(nodes[0].label_year, Some(2024));
        assert_eq!(nodes[1].label_year, None);
        assert_eq!(nodes[1].entries.len(), 1);
    }

    #[test]
    fn build_date_groups_property_pointing_at_missing_column_falls_back_to_no_date() {
        let real = Uuid::new_v4();
        let phantom = Uuid::new_v4();
        let db = make_book_with_date_prop(real);
        let entries = vec![entry_with_date(real, "2024-01-15")];
        let g = DateGrouping {
            source: DateGroupingSource::Property(phantom),
            granularity: DateGranularity::Year,
            ascending: false,
        };
        let nodes = build_date_groups(&db, entries, &g);
        assert_eq!(nodes.len(), 1);
        assert_eq!(nodes[0].label_year, None);
    }

    #[test]
    fn total_entries_walks_children() {
        let node = DateGroupNode {
            label_year: Some(2024),
            label_month: None,
            label_day: None,
            entries: vec![],
            children: vec![
                DateGroupNode {
                    label_year: Some(2024),
                    label_month: Some(1),
                    label_day: None,
                    entries: vec![Entry::new(HashMap::new()), Entry::new(HashMap::new())],
                    children: vec![],
                },
                DateGroupNode {
                    label_year: Some(2024),
                    label_month: Some(2),
                    label_day: None,
                    entries: vec![Entry::new(HashMap::new())],
                    children: vec![],
                },
            ],
        };
        assert_eq!(node.total_entries(), 3);
    }

    #[test]
    fn build_date_groups_month_granularity_buckets_by_year_and_month() {
        let prop = Uuid::new_v4();
        let db = make_book_with_date_prop(prop);
        let entries = vec![
            entry_with_date(prop, "2024-01-15"),
            entry_with_date(prop, "2024-01-20"),
            entry_with_date(prop, "2024-03-01"),
        ];
        let g = DateGrouping {
            source: DateGroupingSource::Property(prop),
            granularity: DateGranularity::Month,
            ascending: true,
        };
        let nodes = build_date_groups(&db, entries, &g);
        assert_eq!(nodes.len(), 2);
        // Ascending : January first, then March.
        assert_eq!(nodes[0].label_year, Some(2024));
        assert_eq!(nodes[0].label_month, Some(1));
        assert_eq!(nodes[0].entries.len(), 2);
        assert_eq!(nodes[1].label_month, Some(3));
    }

    #[test]
    fn build_date_groups_day_granularity_buckets_by_exact_day() {
        let prop = Uuid::new_v4();
        let db = make_book_with_date_prop(prop);
        let entries = vec![
            entry_with_date(prop, "2024-01-15"),
            entry_with_date(prop, "2024-01-15"),
            entry_with_date(prop, "2024-01-16"),
        ];
        let g = DateGrouping {
            source: DateGroupingSource::Property(prop),
            granularity: DateGranularity::Day,
            ascending: false,
        };
        let nodes = build_date_groups(&db, entries, &g);
        assert_eq!(nodes.len(), 2);
        // Descending : Jan 16 then Jan 15. The two Jan 15 entries share one
        // bucket.
        assert_eq!(nodes[0].label_day, Some(16));
        assert_eq!(nodes[1].label_day, Some(15));
        assert_eq!(nodes[1].entries.len(), 2);
    }

    #[test]
    fn build_date_groups_uses_created_source() {
        let prop = Uuid::new_v4();
        let db = make_book_with_date_prop(prop);
        // No Date prop value — Created falls back to the entry's
        // auto-generated created_at (an RFC 3339 timestamp).
        let entry = Entry::new(HashMap::new());
        let g = DateGrouping {
            source: DateGroupingSource::Created,
            granularity: DateGranularity::Year,
            ascending: false,
        };
        let nodes = build_date_groups(&db, vec![entry], &g);
        assert_eq!(nodes.len(), 1);
        // The entry has a current-time `created_at`, so its year is
        // present and non-`None`. Don't hard-code the year — just
        // confirm it's a valid bucket and not the No-date sentinel.
        assert!(nodes[0].label_year.is_some());
        assert_eq!(nodes[0].entries.len(), 1);
    }

    #[test]
    fn build_date_groups_uses_published_source_with_fallback_to_created() {
        let prop = Uuid::new_v4();
        let db = make_book_with_date_prop(prop);
        // Empty published_at -> source path falls through to created_at.
        let mut entry = Entry::new(HashMap::new());
        entry.published_at = String::new();
        let g = DateGrouping {
            source: DateGroupingSource::Published,
            granularity: DateGranularity::Year,
            ascending: false,
        };
        let nodes = build_date_groups(&db, vec![entry], &g);
        assert_eq!(nodes.len(), 1);
        assert!(nodes[0].label_year.is_some());
    }

    #[test]
    fn parse_ymd_rejects_out_of_range_components() {
        assert_eq!(parse_ymd("2024-00-15"), None); // month 0
        assert_eq!(parse_ymd("2024-12-32"), None); // day 32
        assert_eq!(parse_ymd("2024-13-01"), None); // month 13
        assert_eq!(parse_ymd("short"), None);
        assert_eq!(parse_ymd("2024_01_15"), None); // wrong sep
    }
}
