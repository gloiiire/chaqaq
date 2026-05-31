use crate::application::database_repository::DatabaseRepository;
use crate::application::error::PinkhaError;
use crate::domain::database::{Filter, Sort, View};
use uuid::Uuid;

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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::application::error::PinkhaError;
    use crate::domain::database::{
        Database, DatabaseMeta, FilterCondition, Order, Property, PropertyType, ViewType,
    };
    use crate::domain::document::InlineText;
    use std::cell::RefCell;
    use uuid::Uuid;

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
        fn list_meta(&self) -> Result<Vec<DatabaseMeta>, PinkhaError> {
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
}
