//! Integration tests for the database-row ↔ document title bridge.
//!
//! Renaming a row in a database view should rename the underlying note,
//! provided the row was created with `add_entry_with_document` (i.e. the
//! Notion / Craft import path, or any future "row IS a page" semantics).

use pinkha::application::database_use_cases::{
    add_entry, add_entry_with_document, create_database, get_database,
};
use pinkha::application::use_cases::{
    create_document, get_document, update_entry_propagating_title,
};
use pinkha::domain::database::{Property, PropertyType, PropertyValue};
use pinkha::domain::document::InlineText;
use pinkha::infrastructure::database_store::DatabaseStore;
use pinkha::infrastructure::json_store::JsonStore;
use std::collections::HashMap;
use uuid::Uuid;

fn doc_store() -> JsonStore {
    let dir = std::env::temp_dir().join(format!("pinkha_dds_doc_{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    JsonStore::new(dir)
}

fn db_store() -> DatabaseStore {
    let dir = std::env::temp_dir().join(format!("pinkha_dds_db_{}", Uuid::new_v4()));
    DatabaseStore::new(dir).unwrap()
}

fn span(text: &str) -> Vec<InlineText> {
    vec![InlineText { content: text.into(), styles: vec![] }]
}

#[test]
fn renaming_a_linked_row_renames_the_underlying_document() {
    let docs = doc_store();
    let dbs = db_store();

    // Seed a document.
    let doc = create_document(&docs, "Old name").unwrap();

    // Seed a database with a Title property.
    let title_prop = Property::new("Name", PropertyType::Title);
    let title_prop_id = title_prop.id;
    let db = create_database(&dbs, span("Notes"), vec![title_prop]).unwrap();

    // Link the row to the document.
    let initial: HashMap<Uuid, PropertyValue> = HashMap::from([
        (title_prop_id, PropertyValue::Title(span("Old name"))),
    ]);
    let entry = add_entry_with_document(&dbs, db.id, initial, doc.id).unwrap();

    // Rename via the orchestration use case.
    let renamed: HashMap<Uuid, PropertyValue> = HashMap::from([
        (title_prop_id, PropertyValue::Title(span("New name"))),
    ]);
    update_entry_propagating_title(&docs, &dbs, db.id, entry.id, renamed).unwrap();

    // Both the row AND the document reflect the new name.
    let db = get_database(&dbs, db.id).unwrap();
    match &db.entries[0].values[&title_prop_id] {
        PropertyValue::Title(spans) => {
            let plain: String = spans.iter().map(|s| s.content.as_str()).collect();
            assert_eq!(plain, "New name");
        }
        other => panic!("expected Title, got {other:?}"),
    }

    let doc = get_document(&docs, doc.id).unwrap();
    let plain: String = doc.title.iter().map(|s| s.content.as_str()).collect();
    assert_eq!(plain, "New name");
}

#[test]
fn renaming_an_unlinked_row_does_not_touch_unrelated_documents() {
    let docs = doc_store();
    let dbs = db_store();

    // A document that exists but is NOT linked to any row.
    let bystander = create_document(&docs, "Should stay").unwrap();

    let title_prop = Property::new("Name", PropertyType::Title);
    let title_prop_id = title_prop.id;
    let db = create_database(&dbs, span("DB"), vec![title_prop]).unwrap();

    // Standalone row.
    let initial: HashMap<Uuid, PropertyValue> = HashMap::from([
        (title_prop_id, PropertyValue::Title(span("Row A"))),
    ]);
    let entry = add_entry(&dbs, db.id, initial).unwrap();

    let renamed: HashMap<Uuid, PropertyValue> = HashMap::from([
        (title_prop_id, PropertyValue::Title(span("Row A renamed"))),
    ]);
    update_entry_propagating_title(&docs, &dbs, db.id, entry.id, renamed).unwrap();

    // Bystander document untouched.
    let doc = get_document(&docs, bystander.id).unwrap();
    let plain: String = doc.title.iter().map(|s| s.content.as_str()).collect();
    assert_eq!(plain, "Should stay");
}
