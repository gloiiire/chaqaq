//! Cross-domain orchestration between the database and document repositories.
//!
//! Lives at the application layer so it can depend on **both** `&dyn
//! DocumentRepository` and `&dyn DatabaseRepository` without coupling either
//! domain to the other. The FFI composition root wires concrete stores in.

use std::collections::HashMap;
use uuid::Uuid;

use crate::application::database_use_cases;
use crate::application::error::PinkhaError;
use crate::application::unit_of_work::UnitOfWork;
use crate::application::use_cases as doc_use_cases;
use crate::domain::database::{PropertyType, PropertyValue};

/// Updates a database entry's values and — when the row is backed by a
/// document (`entry.document_id` is `Some`) and the supplied values touch the
/// database's Title property — propagates the new title to the underlying
/// document.
///
/// Fixes the long-standing UX bug where renaming a row in the database view
/// left the corresponding note's name untouched. Idempotent: re-applying the
/// same title is a no-op writer-side because `update_document_title` always
/// re-parses and re-saves.
///
/// Truly cross-domain: touches both the database repository (for the entry
/// update) and the document repository (for the title propagation). When the
/// underlying `UnitOfWork` is transactional, both writes commit or roll back
/// together.
pub fn update_entry_propagating_title(
    uow: &dyn UnitOfWork,
    db_id: Uuid,
    entry_id: Uuid,
    values: HashMap<Uuid, PropertyValue>,
) -> Result<(), PinkhaError> {
    // Capture the entry's document link and the database's Title property
    // before we mutate anything — the post-write reload would still give us
    // the same data, but doing it upfront keeps the function easy to read.
    let db = uow.databases().load(db_id)?;
    let document_id = db
        .entries
        .iter()
        .find(|e| e.id == entry_id)
        .ok_or(PinkhaError::NotFound(entry_id))?
        .document_id;
    let title_prop_id = db
        .properties
        .iter()
        .find(|p| matches!(p.type_, PropertyType::Title))
        .map(|p| p.id);

    // Perform the entry update.
    database_use_cases::update_entry(uow, db_id, entry_id, values.clone())?;

    // Propagate to the document title when applicable.
    if let (Some(doc_id), Some(title_id)) = (document_id, title_prop_id)
        && let Some(PropertyValue::Title(spans)) = values.get(&title_id)
    {
        let plain: String = spans.iter().map(|t| t.content.as_str()).collect();
        doc_use_cases::update_document_title(uow, doc_id, &plain)?;
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::application::database_repository::DatabaseRepository;
    use crate::application::repository::DocumentRepository;
    use crate::application::unit_of_work::test_support::MockUnitOfWork;
    use crate::domain::database::{Database, Property, PropertyType};
    use crate::domain::document::{Document, InlineText};

    use std::collections::HashMap;

    // ── Minimal in-memory mocks ────────────────────────────────────────────

    struct MockDocRepo {
        docs: std::sync::Mutex<HashMap<Uuid, Document>>,
    }
    impl MockDocRepo {
        fn new() -> Self {
            Self {
                docs: std::sync::Mutex::new(HashMap::new()),
            }
        }
        fn seed(&self, doc: Document) {
            self.docs.lock().unwrap().insert(doc.id, doc);
        }
    }
    impl DocumentRepository for MockDocRepo {
        fn save(&self, doc: &Document) -> Result<(), PinkhaError> {
            self.docs.lock().unwrap().insert(doc.id, doc.clone());
            Ok(())
        }
        fn load(&self, id: Uuid) -> Result<Document, PinkhaError> {
            self.docs
                .lock()
                .unwrap()
                .get(&id)
                .cloned()
                .ok_or(PinkhaError::NotFound(id))
        }
        fn list(&self) -> Result<Vec<crate::domain::document::DocumentMeta>, PinkhaError> {
            Ok(self
                .docs
                .lock()
                .unwrap()
                .values()
                .map(crate::domain::document::DocumentMeta::from)
                .collect())
        }
        fn delete(&self, id: Uuid) -> Result<(), PinkhaError> {
            self.docs
                .lock()
                .unwrap()
                .remove(&id)
                .map(|_| ())
                .ok_or(PinkhaError::NotFound(id))
        }
        fn move_to_folder(&self, _: Uuid, _: Option<Uuid>) -> Result<(), PinkhaError> {
            Ok(())
        }
        fn list_by_folder(
            &self,
            _: Option<Uuid>,
        ) -> Result<Vec<crate::domain::document::DocumentMeta>, PinkhaError> {
            self.list()
        }
    }

    struct MockDbRepo {
        dbs: std::sync::Mutex<HashMap<Uuid, Database>>,
    }
    impl MockDbRepo {
        fn new() -> Self {
            Self {
                dbs: std::sync::Mutex::new(HashMap::new()),
            }
        }
        fn seed(&self, db: Database) {
            self.dbs.lock().unwrap().insert(db.id, db);
        }
    }
    impl DatabaseRepository for MockDbRepo {
        fn save(&self, db: &Database) -> Result<(), PinkhaError> {
            self.dbs.lock().unwrap().insert(db.id, db.clone());
            Ok(())
        }
        fn load(&self, id: Uuid) -> Result<Database, PinkhaError> {
            self.dbs
                .lock()
                .unwrap()
                .get(&id)
                .cloned()
                .ok_or(PinkhaError::NotFound(id))
        }
        fn list_meta(&self) -> Result<Vec<crate::domain::database::DatabaseMeta>, PinkhaError> {
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

    fn span(text: &str) -> Vec<InlineText> {
        vec![InlineText {
            content: text.into(),
            styles: vec![],
        }]
    }

    fn seed_db_with_title_prop(repo: &MockDbRepo) -> (Uuid, Uuid) {
        let title_prop = Property::new("Name", PropertyType::Title);
        let title_prop_id = title_prop.id;
        let db = Database::new(span("Tasks"), vec![title_prop]);
        let db_id = db.id;
        repo.seed(db);
        (db_id, title_prop_id)
    }

    // ── Tests ──────────────────────────────────────────────────────────────

    #[test]
    fn renames_document_when_entry_is_backed_by_one() {
        let docs = MockDocRepo::new();
        let dbs = MockDbRepo::new();
        let (db_id, title_prop_id) = seed_db_with_title_prop(&dbs);

        // Seed a document the entry points to.
        let doc = Document::new(span("Old title"));
        let doc_id = doc.id;
        docs.seed(doc);

        // Add a row linked to that document.
        let initial_values: HashMap<Uuid, PropertyValue> =
            HashMap::from([(title_prop_id, PropertyValue::Title(span("Old title")))]);
        let entry = database_use_cases::add_entry_with_document(
            &MockUnitOfWork::with_dbs(&dbs),
            db_id,
            initial_values,
            doc_id,
        )
        .unwrap();

        // Rename the row.
        let new_values: HashMap<Uuid, PropertyValue> =
            HashMap::from([(title_prop_id, PropertyValue::Title(span("Brand new title")))]);
        update_entry_propagating_title(
            &MockUnitOfWork {
                docs: Some(&docs),
                dbs: Some(&dbs),
                folders: None,
            },
            db_id,
            entry.id,
            new_values,
        )
        .unwrap();

        // Document was renamed under the hood.
        let updated_doc = docs.load(doc_id).unwrap();
        let plain: String = updated_doc
            .title
            .iter()
            .map(|s| s.content.as_str())
            .collect();
        assert_eq!(plain, "Brand new title");
    }

    #[test]
    fn leaves_document_alone_when_entry_has_no_document_link() {
        let docs = MockDocRepo::new();
        let dbs = MockDbRepo::new();
        let (db_id, title_prop_id) = seed_db_with_title_prop(&dbs);

        // Standalone document — must not be touched even with the same UUID space.
        let doc = Document::new(span("Untouched"));
        let doc_id = doc.id;
        docs.seed(doc);

        // Row with no document_id (standalone tabular data).
        let initial_values: HashMap<Uuid, PropertyValue> =
            HashMap::from([(title_prop_id, PropertyValue::Title(span("row title")))]);
        let entry =
            database_use_cases::add_entry(&MockUnitOfWork::with_dbs(&dbs), db_id, initial_values)
                .unwrap();

        let new_values: HashMap<Uuid, PropertyValue> =
            HashMap::from([(title_prop_id, PropertyValue::Title(span("renamed row")))]);
        update_entry_propagating_title(
            &MockUnitOfWork {
                docs: Some(&docs),
                dbs: Some(&dbs),
                folders: None,
            },
            db_id,
            entry.id,
            new_values,
        )
        .unwrap();

        // Original doc unchanged — sanity check.
        let untouched = docs.load(doc_id).unwrap();
        let plain: String = untouched.title.iter().map(|s| s.content.as_str()).collect();
        assert_eq!(plain, "Untouched");
    }

    #[test]
    fn no_op_when_values_do_not_include_title_property() {
        let docs = MockDocRepo::new();
        let dbs = MockDbRepo::new();
        let (db_id, title_prop_id) = seed_db_with_title_prop(&dbs);

        let doc = Document::new(span("Stable title"));
        let doc_id = doc.id;
        docs.seed(doc);

        let initial_values: HashMap<Uuid, PropertyValue> =
            HashMap::from([(title_prop_id, PropertyValue::Title(span("Stable title")))]);
        let entry = database_use_cases::add_entry_with_document(
            &MockUnitOfWork::with_dbs(&dbs),
            db_id,
            initial_values,
            doc_id,
        )
        .unwrap();

        // Update some non-Title property (the same Title slot left out entirely).
        let new_values: HashMap<Uuid, PropertyValue> = HashMap::new();
        update_entry_propagating_title(
            &MockUnitOfWork {
                docs: Some(&docs),
                dbs: Some(&dbs),
                folders: None,
            },
            db_id,
            entry.id,
            new_values,
        )
        .unwrap();

        // Document title is untouched.
        let untouched = docs.load(doc_id).unwrap();
        let plain: String = untouched.title.iter().map(|s| s.content.as_str()).collect();
        assert_eq!(plain, "Stable title");
    }

    #[test]
    fn returns_not_found_for_unknown_entry() {
        let docs = MockDocRepo::new();
        let dbs = MockDbRepo::new();
        let (db_id, _) = seed_db_with_title_prop(&dbs);

        let res = update_entry_propagating_title(
            &MockUnitOfWork {
                docs: Some(&docs),
                dbs: Some(&dbs),
                folders: None,
            },
            db_id,
            Uuid::new_v4(),
            HashMap::new(),
        );
        assert!(matches!(res, Err(PinkhaError::NotFound(_))));
    }
}
