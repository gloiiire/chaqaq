//! Integration tests for the book-row ↔ leaf title bridge.
//!
//! Renaming a row in a book view should rename the underlying note,
//! provided the row was created with `add_entry_with_leaf` (i.e. the
//! Notion / Craft import path, or any future "row IS a page" semantics).

use pinkha::application::book_use_cases::{
    add_entry, add_entry_with_leaf, create_book, get_book,
};
use pinkha::application::use_cases::{
    create_leaf, get_leaf, update_entry_propagating_title,
};
use pinkha::domain::book::{Property, PropertyType, PropertyValue};
use pinkha::domain::leaf::InlineText;
use pinkha::infrastructure::book_store::BookStore;
use pinkha::infrastructure::json_store::JsonStore;
use std::collections::HashMap;
use uuid::Uuid;

fn leaf_store() -> JsonStore {
    let dir = std::env::temp_dir().join(format!("pinkha_dds_leaf_{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    JsonStore::new(dir)
}

fn book_store() -> BookStore {
    let dir = std::env::temp_dir().join(format!("pinkha_dds_book_{}", Uuid::new_v4()));
    BookStore::new(dir).unwrap()
}

fn span(text: &str) -> Vec<InlineText> {
    vec![InlineText {
        content: text.into(),
        styles: vec![],
    }]
}

#[test]
fn renaming_a_linked_row_renames_the_underlying_leaf() {
    let docs = leaf_store();
    let dbs = book_store();

    // Seed a leaf.
    let doc = create_leaf(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&docs),
        "Old name",
    )
    .unwrap();

    // Seed a book with a Title property.
    let title_prop = Property::new("Name", PropertyType::Title);
    let title_prop_id = title_prop.id;
    let db = create_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&dbs),
        span("Notes"),
        vec![title_prop],
    )
    .unwrap();

    // Link the row to the leaf.
    let initial: HashMap<Uuid, PropertyValue> =
        HashMap::from([(title_prop_id, PropertyValue::Title(span("Old name")))]);
    let entry = add_entry_with_leaf(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&dbs),
        db.id,
        initial,
        doc.id,
    )
    .unwrap();

    // Rename via the orchestration use case.
    let renamed: HashMap<Uuid, PropertyValue> =
        HashMap::from([(title_prop_id, PropertyValue::Title(span("New name")))]);
    update_entry_propagating_title(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves_books(&docs, &dbs),
        db.id,
        entry.id,
        renamed,
    )
    .unwrap();

    // Both the row AND the leaf reflect the new name.
    let db = get_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&dbs),
        db.id,
    )
    .unwrap();
    match &db.entries[0].values[&title_prop_id] {
        PropertyValue::Title(spans) => {
            let plain: String = spans.iter().map(|s| s.content.as_str()).collect();
            assert_eq!(plain, "New name");
        }
        other => panic!("expected Title, got {other:?}"),
    }

    let doc = get_leaf(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&docs),
        doc.id,
    )
    .unwrap();
    let plain: String = doc.title.iter().map(|s| s.content.as_str()).collect();
    assert_eq!(plain, "New name");
}

#[test]
fn renaming_an_unlinked_row_does_not_touch_unrelated_leaves() {
    let docs = leaf_store();
    let dbs = book_store();

    // A leaf that exists but is NOT linked to any row.
    let bystander = create_leaf(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&docs),
        "Should stay",
    )
    .unwrap();

    let title_prop = Property::new("Name", PropertyType::Title);
    let title_prop_id = title_prop.id;
    let db = create_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&dbs),
        span("DB"),
        vec![title_prop],
    )
    .unwrap();

    // Standalone row.
    let initial: HashMap<Uuid, PropertyValue> =
        HashMap::from([(title_prop_id, PropertyValue::Title(span("Row A")))]);
    let entry = add_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&dbs),
        db.id,
        initial,
    )
    .unwrap();

    let renamed: HashMap<Uuid, PropertyValue> =
        HashMap::from([(title_prop_id, PropertyValue::Title(span("Row A renamed")))]);
    update_entry_propagating_title(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves_books(&docs, &dbs),
        db.id,
        entry.id,
        renamed,
    )
    .unwrap();

    // Bystander leaf untouched.
    let doc = get_leaf(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&docs),
        bystander.id,
    )
    .unwrap();
    let plain: String = doc.title.iter().map(|s| s.content.as_str()).collect();
    assert_eq!(plain, "Should stay");
}
