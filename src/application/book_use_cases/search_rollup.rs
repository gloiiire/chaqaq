use crate::application::book_use_cases::query::calculate_aggregate;
use crate::application::error::PinkhaError;
use crate::application::unit_of_work::UnitOfWork;
use crate::domain::book::{Aggregate, Book, Entry, PropertyType, PropertyValue};
use uuid::Uuid;

/// Case-insensitive search across all text-bearing property values of a book's entries.
pub fn search_entries(
    uow: &dyn UnitOfWork,
    book_id: Uuid,
    query: &str,
) -> Result<Vec<Entry>, PinkhaError> {
    let db = uow.books().load(book_id)?;
    let q = query.to_lowercase();
    Ok(db
        .entries
        .into_iter()
        .filter(|e| !e.is_deleted())
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
        PropertyValue::SelectionMultiple(vs) => vs.iter().any(|s| s.to_lowercase().contains(query)),
        PropertyValue::Title(inlines) => inlines
            .iter()
            .any(|i| i.content.to_lowercase().contains(query)),
        _ => false,
    }
}

/// Enriches entries with computed values for all Rollup columns.
///
/// Rollup values are not persisted — they are recalculated at read time.
pub fn evaluate_rollups(
    uow: &dyn UnitOfWork,
    db: &Book,
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
        let linked_book_id = db
            .properties
            .iter()
            .find(|p| p.id == relation_prop_id)
            .and_then(|p| match &p.type_ {
                PropertyType::Relation { book_id } => Some(*book_id),
                _ => None,
            })
            .ok_or(PinkhaError::NotFound(relation_prop_id))?;

        let linked_book = uow.books().load(linked_book_id)?;

        for entry in &mut entries {
            let linked_ids = match entry.values.get(&relation_prop_id) {
                Some(PropertyValue::Relation(ids)) => ids.clone(),
                _ => vec![],
            };
            let linked_entries: Vec<&Entry> = linked_book
                .entries
                .iter()
                .filter(|e| !e.is_deleted())
                .filter(|e| linked_ids.contains(&e.id))
                .collect();
            entry.values.insert(
                rollup_id,
                calculate_aggregate(&linked_entries, target_prop_id, &aggregate),
            );
        }
    }

    Ok(entries)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::application::book_repository::BookRepository;
    use crate::application::error::PinkhaError;
    use crate::application::unit_of_work::test_support::MockUnitOfWork;
    use crate::domain::book::{Book, BookMeta};

    use uuid::Uuid;

    struct MockDbRepo {
        dbs: std::sync::Mutex<std::collections::HashMap<Uuid, Book>>,
    }

    impl MockDbRepo {
        fn new() -> Self {
            Self {
                dbs: std::sync::Mutex::new(std::collections::HashMap::new()),
            }
        }
    }

    impl BookRepository for MockDbRepo {
        fn save(&self, db: &Book) -> Result<(), PinkhaError> {
            self.dbs.lock().unwrap().insert(db.id, db.clone());
            Ok(())
        }
        fn load(&self, id: Uuid) -> Result<Book, PinkhaError> {
            self.dbs
                .lock()
                .unwrap()
                .get(&id)
                .cloned()
                .ok_or(PinkhaError::NotFound(id))
        }
        fn list_meta(&self) -> Result<Vec<BookMeta>, PinkhaError> {
            Ok(self
                .dbs
                .lock()
                .unwrap()
                .values()
                .map(|db| db.meta())
                .collect())
        }
        fn delete(&self, id: Uuid) -> Result<(), PinkhaError> {
            self.dbs
                .lock()
                .unwrap()
                .remove(&id)
                .map(|_| ())
                .ok_or(PinkhaError::NotFound(id))
        }
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

    #[test]
    fn test_search_entries_book_vide() {
        use crate::domain::leaf::InlineText;
        let repo = MockDbRepo::new();
        let db = Book::new(
            vec![InlineText {
                content: "DB".to_string(),
                styles: vec![],
            }],
            vec![],
        );
        repo.save(&db).unwrap();

        let uow = MockUnitOfWork::with_books(&repo);
        let results = search_entries(&uow, db.id, "test").unwrap();
        assert!(results.is_empty());
    }
}
