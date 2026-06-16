use crate::application::error::PinkhaError;
use crate::application::unit_of_work::UnitOfWork;
use crate::domain::book::{Filter, Order, Sort, SortSource, View};
use uuid::Uuid;

/// Adds a new view to the book and persists.
pub fn add_view(uow: &dyn UnitOfWork, book_id: Uuid, view: View) -> Result<View, PinkhaError> {
    let repo = uow.books();
    let mut db = repo.load(book_id)?;
    db.views.push(view.clone());
    repo.save(&db)?;
    Ok(view)
}

/// Replaces the filters and sorts of an existing view and persists.
pub fn update_view(
    uow: &dyn UnitOfWork,
    book_id: Uuid,
    view_id: Uuid,
    filters: Vec<Filter>,
    sorts: Vec<Sort>,
) -> Result<(), PinkhaError> {
    let repo = uow.books();
    let mut db = repo.load(book_id)?;
    let view = db
        .views
        .iter_mut()
        .find(|v| v.id == view_id)
        .ok_or(PinkhaError::NotFound(view_id))?;
    view.filters = filters;
    view.sorts = sorts;
    repo.save(&db)
}

/// Sets a single sort on a view, replacing whatever sorts were previously
/// configured. When `property_id` is `None`, all sorts are cleared.
///
/// This is the UX-facing entry point for "tap a column header to sort" —
/// callers don't need to know about `Sort`, `SortSource`, or filter shapes.
pub fn set_view_single_sort(
    uow: &dyn UnitOfWork,
    book_id: Uuid,
    view_id: Uuid,
    property_id: Option<Uuid>,
    ascending: bool,
) -> Result<(), PinkhaError> {
    let repo = uow.books();
    let mut db = repo.load(book_id)?;
    let view = db
        .views
        .iter_mut()
        .find(|v| v.id == view_id)
        .ok_or(PinkhaError::NotFound(view_id))?;
    view.sorts = match property_id {
        None => Vec::new(),
        Some(pid) => vec![Sort {
            property_id: pid,
            order: if ascending {
                Order::Ascending
            } else {
                Order::Descending
            },
            source: SortSource::Property,
        }],
    };
    repo.save(&db)
}

/// Sets the active view's sort to the entry-level timestamp sources :
/// `created_at` or `published_at`. `property_id` is ignored — both
/// timestamps live on `Entry`, not on a column. Pass `None` to clear
/// the sort entirely (same vocabulary as `set_view_single_sort`).
pub fn set_view_date_sort(
    uow: &dyn UnitOfWork,
    book_id: Uuid,
    view_id: Uuid,
    source: SortSource,
    ascending: bool,
) -> Result<(), PinkhaError> {
    let repo = uow.books();
    let mut db = repo.load(book_id)?;
    let view = db
        .views
        .iter_mut()
        .find(|v| v.id == view_id)
        .ok_or(PinkhaError::NotFound(view_id))?;
    view.sorts = vec![Sort {
        property_id: Uuid::nil(),
        order: if ascending {
            Order::Ascending
        } else {
            Order::Descending
        },
        source,
    }];
    repo.save(&db)
}

/// Removes a view and persists.
///
/// Returns `InvalidOperation` when attempting to delete the last remaining view.
pub fn delete_view(uow: &dyn UnitOfWork, book_id: Uuid, view_id: Uuid) -> Result<(), PinkhaError> {
    let repo = uow.books();
    let mut db = repo.load(book_id)?;
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::application::book_repository::BookRepository;
    use crate::application::error::PinkhaError;
    use crate::application::unit_of_work::test_support::MockUnitOfWork;
    use crate::domain::book::{
        Book, BookMeta, FilterCondition, Order, Property, PropertyType, ViewType,
    };
    use crate::domain::leaf::InlineText;

    use uuid::Uuid;

    fn book_uow(repo: &MockDbRepo) -> MockUnitOfWork<'_> {
        MockUnitOfWork::with_books(repo)
    }

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

    fn title(s: &str) -> Vec<InlineText> {
        vec![InlineText {
            content: s.to_string(),
            styles: vec![],
        }]
    }

    #[test]
    fn test_update_view_met_a_jour_filters_et_sorts() {
        let repo = MockDbRepo::new();
        let prop = Property::new("Note", PropertyType::Number);
        let prop_id = prop.id;
        let db = Book::new(title("DB"), vec![prop]);
        let view_id = db.views[0].id;
        repo.save(&db).unwrap();

        let filter = Filter {
            property_id: prop_id,
            condition: FilterCondition::IsFilled,
        };
        let sort = Sort::by_property(prop_id, Order::Descending);
        update_view(&book_uow(&repo), db.id, view_id, vec![filter], vec![sort]).unwrap();

        let db = repo.load(db.id).unwrap();
        assert_eq!(db.views[0].filters.len(), 1);
        assert_eq!(db.views[0].sorts.len(), 1);
    }

    #[test]
    fn test_delete_view() {
        let repo = MockDbRepo::new();
        let mut db = Book::new(title("DB"), vec![]);
        let view2 = View::new("Kanban", ViewType::Gallery);
        let view2_id = view2.id;
        db.views.push(view2);
        repo.save(&db).unwrap();

        delete_view(&book_uow(&repo), db.id, view2_id).unwrap();

        let db = repo.load(db.id).unwrap();
        assert_eq!(db.views.len(), 1);
        assert!(db.views.iter().all(|v| v.id != view2_id));
    }

    #[test]
    fn test_supprimer_derniere_vue_erreur() {
        let repo = MockDbRepo::new();
        let db = Book::new(title("DB"), vec![]);
        let view_id = db.views[0].id;
        repo.save(&db).unwrap();

        let res = delete_view(&book_uow(&repo), db.id, view_id);
        assert!(matches!(res, Err(PinkhaError::InvalidOperation(_))));
    }

    #[test]
    fn test_delete_view_inexistante_erreur() {
        let repo = MockDbRepo::new();
        let mut db = Book::new(title("DB"), vec![]);
        db.views.push(View::new("Extra", ViewType::Gallery));
        repo.save(&db).unwrap();

        let res = delete_view(&book_uow(&repo), db.id, Uuid::new_v4());
        assert!(matches!(res, Err(PinkhaError::NotFound(_))));
    }

    // ── set_view_single_sort ─────────────────────────────────────────────────

    #[test]
    fn set_view_single_sort_replaces_previous_sorts() {
        let repo = MockDbRepo::new();
        let title_prop = Property::new("Name", PropertyType::Title);
        let title_id = title_prop.id;
        let date_prop = Property::new("Date", PropertyType::Date);
        let date_id = date_prop.id;
        let db = Book::new(
            vec![InlineText {
                content: "Tasks".into(),
                styles: vec![],
            }],
            vec![title_prop, date_prop],
        );
        let book_id = db.id;
        let view_id = db.views[0].id;
        repo.save(&db).unwrap();

        // First sort: title ascending.
        set_view_single_sort(&book_uow(&repo), book_id, view_id, Some(title_id), true).unwrap();
        let after_first = repo.load(book_id).unwrap();
        assert_eq!(after_first.views[0].sorts.len(), 1);
        assert_eq!(after_first.views[0].sorts[0].property_id, title_id);
        assert_eq!(after_first.views[0].sorts[0].order, Order::Ascending);

        // Replace with date descending — previous sort is gone, not stacked.
        set_view_single_sort(&book_uow(&repo), book_id, view_id, Some(date_id), false).unwrap();
        let after_second = repo.load(book_id).unwrap();
        assert_eq!(after_second.views[0].sorts.len(), 1);
        assert_eq!(after_second.views[0].sorts[0].property_id, date_id);
        assert_eq!(after_second.views[0].sorts[0].order, Order::Descending);
    }

    #[test]
    fn set_view_single_sort_with_none_clears_sorts() {
        let repo = MockDbRepo::new();
        let prop = Property::new("Name", PropertyType::Title);
        let prop_id = prop.id;
        let db = Book::new(
            vec![InlineText {
                content: "Tasks".into(),
                styles: vec![],
            }],
            vec![prop],
        );
        let book_id = db.id;
        let view_id = db.views[0].id;
        repo.save(&db).unwrap();

        set_view_single_sort(&book_uow(&repo), book_id, view_id, Some(prop_id), true).unwrap();
        set_view_single_sort(&book_uow(&repo), book_id, view_id, None, true).unwrap();

        let loaded = repo.load(book_id).unwrap();
        assert!(loaded.views[0].sorts.is_empty());
    }

    #[test]
    fn set_view_single_sort_unknown_view_returns_not_found() {
        let repo = MockDbRepo::new();
        let db = Book::new(
            vec![InlineText {
                content: "x".into(),
                styles: vec![],
            }],
            vec![],
        );
        let book_id = db.id;
        repo.save(&db).unwrap();

        let res = set_view_single_sort(&book_uow(&repo), book_id, Uuid::new_v4(), None, true);
        assert!(matches!(res, Err(PinkhaError::NotFound(_))));
    }
}
