use pinkha::application::database_use_cases::{
    add_entry, create_database, delete_database, get_database, list_databases,
};
use pinkha::application::error::PinkhaError;
use pinkha::application::use_cases::{
    add_block, create_document, delete_document, get_document, list_documents,
};
use pinkha::domain::database::{Property, PropertyType, PropertyValue};
use pinkha::domain::document::{BlockContent, InlineText};
use pinkha::infrastructure::database_store::DatabaseStore;
use pinkha::infrastructure::json_store::JsonStore;
use std::collections::HashMap;
use uuid::Uuid;

fn doc_store_temp() -> JsonStore {
    let dir = std::env::temp_dir().join(format!("pinkha_e2e_del_doc_{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    JsonStore::new(dir)
}

fn db_store_temp() -> DatabaseStore {
    let dir = std::env::temp_dir().join(format!("pinkha_e2e_del_db_{}", Uuid::new_v4()));
    DatabaseStore::new(dir).unwrap()
}

fn inlines(s: &str) -> Vec<InlineText> {
    vec![InlineText {
        content: s.to_string(),
        styles: vec![],
    }]
}

/// Creates several documents, deletes one, verifies the list and inaccessibility.
#[test]
fn test_flux_suppression_document() {
    let store = doc_store_temp();

    let doc_a = create_document(&store, "Projet Alpha").unwrap();
    let doc_b = create_document(&store, "Projet Beta").unwrap();
    let doc_c = create_document(&store, "Projet Gamma").unwrap();

    // Add blocks to A to ensure deleting A does not affect B/C
    add_block(
        &store,
        doc_a.id,
        BlockContent::Text(inlines("Note interne")),
    )
    .unwrap();

    delete_document(&store, doc_b.id).unwrap();

    // B is inaccessible
    assert!(matches!(
        get_document(&store, doc_b.id),
        Err(PinkhaError::NotFound(_))
    ));

    // A and C are intact
    let a = get_document(&store, doc_a.id).unwrap();
    assert_eq!(a.blocks.len(), 1);
    assert!(get_document(&store, doc_c.id).is_ok());

    // The listing no longer contains B
    let liste = list_documents(&store).unwrap();
    assert_eq!(liste.len(), 2);
    assert!(!liste.iter().any(|m| m.id == doc_b.id));
}

/// Creates a database with entries, deletes it, verifies inaccessibility.
#[test]
fn test_flux_suppression_database() {
    let store = db_store_temp();

    let prop = Property::new("Nom", PropertyType::Text);
    let prop_id = prop.id;

    let db_a = create_database(&store, inlines("Archive"), vec![prop]).unwrap();
    let db_b = create_database(&store, inlines("Active"), vec![]).unwrap();

    // Add an entry to Archive
    let mut v = HashMap::new();
    v.insert(prop_id, PropertyValue::Text("Ancienne note".to_string()));
    add_entry(&store, db_a.id, v).unwrap();

    delete_database(&store, db_a.id).unwrap();

    // Archive is inaccessible
    assert!(matches!(
        get_database(&store, db_a.id),
        Err(PinkhaError::NotFound(_))
    ));

    // Active remains intact
    assert!(get_database(&store, db_b.id).is_ok());

    // The listing no longer contains Archive
    let liste = list_databases(&store).unwrap();
    assert_eq!(liste.len(), 1);
    assert_eq!(liste[0].id, db_b.id);
}

/// A double deletion returns NotFound on the second attempt.
#[test]
fn test_double_suppression_retourne_erreur() {
    let store = doc_store_temp();
    let doc = create_document(&store, "Unique").unwrap();

    delete_document(&store, doc.id).unwrap();
    let result = delete_document(&store, doc.id);
    assert!(matches!(result, Err(PinkhaError::NotFound(_))));
}
