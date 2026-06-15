use pinkha::application::book_use_cases::{
    add_entry, create_book, delete_book, get_book, list_books,
};
use pinkha::application::error::PinkhaError;
use pinkha::application::use_cases::{
    add_block, create_leaf, delete_leaf, get_leaf, list_leaves,
};
use pinkha::domain::book::{Property, PropertyType, PropertyValue};
use pinkha::domain::leaf::{BlockContent, InlineText};
use pinkha::infrastructure::book_store::BookStore;
use pinkha::infrastructure::json_store::JsonStore;
use std::collections::HashMap;
use uuid::Uuid;

fn leaf_store_temp() -> JsonStore {
    let dir = std::env::temp_dir().join(format!("pinkha_e2e_del_leaf_{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    JsonStore::new(dir)
}

fn book_store_temp() -> BookStore {
    let dir = std::env::temp_dir().join(format!("pinkha_e2e_del_book_{}", Uuid::new_v4()));
    BookStore::new(dir).unwrap()
}

fn inlines(s: &str) -> Vec<InlineText> {
    vec![InlineText {
        content: s.to_string(),
        styles: vec![],
    }]
}

/// Creates several leaves, deletes one, verifies the list and inaccessibility.
#[test]
fn test_flux_suppression_leaf() {
    let store = leaf_store_temp();

    let leaf_a = create_leaf(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
        "Projet Alpha",
    )
    .unwrap();
    let leaf_b = create_leaf(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
        "Projet Beta",
    )
    .unwrap();
    let leaf_c = create_leaf(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
        "Projet Gamma",
    )
    .unwrap();

    // Add blocks to A to ensure deleting A does not affect B/C
    add_block(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
        leaf_a.id,
        BlockContent::Text(inlines("Note interne")),
    )
    .unwrap();

    delete_leaf(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
        leaf_b.id,
    )
    .unwrap();

    // B is inaccessible
    assert!(matches!(
        get_leaf(
            &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
            leaf_b.id
        ),
        Err(PinkhaError::NotFound(_))
    ));

    // A and C are intact
    let a = get_leaf(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
        leaf_a.id,
    )
    .unwrap();
    assert_eq!(a.blocks.len(), 1);
    assert!(
        get_leaf(
            &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
            leaf_c.id
        )
        .is_ok()
    );

    // The listing no longer contains B
    let liste = list_leaves(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
    )
    .unwrap();
    assert_eq!(liste.len(), 2);
    assert!(!liste.iter().any(|m| m.id == leaf_b.id));
}

/// Creates a book with entries, deletes it, verifies inaccessibility.
#[test]
fn test_flux_suppression_book() {
    let store = book_store_temp();

    let prop = Property::new("Nom", PropertyType::Text);
    let prop_id = prop.id;

    let book_a = create_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        inlines("Archive"),
        vec![prop],
    )
    .unwrap();
    let book_b = create_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        inlines("Active"),
        vec![],
    )
    .unwrap();

    // Add an entry to Archive
    let mut v = HashMap::new();
    v.insert(prop_id, PropertyValue::Text("Ancienne note".to_string()));
    add_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        book_a.id,
        v,
    )
    .unwrap();

    delete_book(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
        book_a.id,
    )
    .unwrap();

    // Archive is inaccessible
    assert!(matches!(
        get_book(
            &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
            book_a.id
        ),
        Err(PinkhaError::NotFound(_))
    ));

    // Active remains intact
    assert!(
        get_book(
            &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
            book_b.id
        )
        .is_ok()
    );

    // The listing no longer contains Archive
    let liste = list_books(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_books(&store),
    )
    .unwrap();
    assert_eq!(liste.len(), 1);
    assert_eq!(liste[0].id, book_b.id);
}

/// A double deletion returns NotFound on the second attempt.
#[test]
fn test_double_suppression_retourne_erreur() {
    let store = leaf_store_temp();
    let doc = create_leaf(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
        "Unique",
    )
    .unwrap();

    delete_leaf(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
        doc.id,
    )
    .unwrap();
    let result = delete_leaf(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
        doc.id,
    );
    assert!(matches!(result, Err(PinkhaError::NotFound(_))));
}
