use pinkha::application::database_use_cases::{add_entry, create_database, search_entries};
use pinkha::application::use_cases::{create_document, search_documents};
use pinkha::domain::database::{Property, PropertyType, PropertyValue};
use pinkha::domain::document::InlineText;
use pinkha::infrastructure::database_store::DatabaseStore;
use pinkha::infrastructure::json_store::JsonStore;
use std::collections::HashMap;
use uuid::Uuid;

fn doc_store_temp() -> JsonStore {
    let dir = std::env::temp_dir().join(format!("pinkha_search_doc_{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    JsonStore::new(dir)
}

fn db_store_temp() -> DatabaseStore {
    let dir = std::env::temp_dir().join(format!("pinkha_search_db_{}", Uuid::new_v4()));
    DatabaseStore::new(dir).unwrap()
}

fn inlines(s: &str) -> Vec<InlineText> {
    vec![InlineText {
        content: s.to_string(),
        styles: vec![],
    }]
}

// ── Document search ───────────────────────────────────────────────────────────

#[test]
fn test_search_documents_par_title() {
    let store = doc_store_temp();
    create_document(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_docs(&store),
        "Journal de voyage",
    )
    .unwrap();
    create_document(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_docs(&store),
        "Recettes de cuisine",
    )
    .unwrap();
    create_document(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_docs(&store),
        "Journal personnel",
    )
    .unwrap();

    let resultats = search_documents(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_docs(&store),
        "journal",
    )
    .unwrap();
    assert_eq!(resultats.len(), 2);
}

#[test]
fn test_search_documents_insensible_casse() {
    let store = doc_store_temp();
    create_document(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_docs(&store),
        "Notes de Réunion",
    )
    .unwrap();
    create_document(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_docs(&store),
        "Todo list",
    )
    .unwrap();

    let resultats = search_documents(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_docs(&store),
        "NOTES",
    )
    .unwrap();
    assert_eq!(resultats.len(), 1);
}

#[test]
fn test_search_documents_aucun_resultat() {
    let store = doc_store_temp();
    create_document(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_docs(&store),
        "Journal",
    )
    .unwrap();

    let resultats = search_documents(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_docs(&store),
        "xyzzy",
    )
    .unwrap();
    assert!(resultats.is_empty());
}

#[test]
fn test_search_documents_query_vide_retourne_tout() {
    let store = doc_store_temp();
    create_document(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_docs(&store),
        "Doc A",
    )
    .unwrap();
    create_document(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_docs(&store),
        "Doc B",
    )
    .unwrap();

    let resultats = search_documents(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_docs(&store),
        "",
    )
    .unwrap();
    assert_eq!(resultats.len(), 2);
}

// ── Database entry search ─────────────────────────────────────────────────────

#[test]
fn test_search_entries_par_texte() {
    let store = db_store_temp();
    let prop = Property::new("Contenu", PropertyType::Text);
    let prop_id = prop.id;
    let db = create_database(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_dbs(&store),
        inlines("Notes"),
        vec![prop],
    )
    .unwrap();

    for texte in ["Première pensée", "Deuxième réflexion", "Troisième pensée"] {
        let mut v = HashMap::new();
        v.insert(prop_id, PropertyValue::Text(texte.to_string()));
        add_entry(
            &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_dbs(&store),
            db.id,
            v,
        )
        .unwrap();
    }

    let resultats = search_entries(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_dbs(&store),
        db.id,
        "pensée",
    )
    .unwrap();
    assert_eq!(resultats.len(), 2);
}

#[test]
fn test_search_entries_insensible_casse() {
    let store = db_store_temp();
    let prop = Property::new("Titre", PropertyType::Text);
    let prop_id = prop.id;
    let db = create_database(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_dbs(&store),
        inlines("DB"),
        vec![prop],
    )
    .unwrap();

    let mut v = HashMap::new();
    v.insert(prop_id, PropertyValue::Text("Vacances d'Été".to_string()));
    add_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_dbs(&store),
        db.id,
        v,
    )
    .unwrap();

    let resultats = search_entries(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_dbs(&store),
        db.id,
        "été",
    )
    .unwrap();
    assert_eq!(resultats.len(), 1);
}

#[test]
fn test_search_entries_multi_champs() {
    let store = db_store_temp();
    let prop_title = Property::new("Titre", PropertyType::Text);
    let prop_tags = Property::new("Tags", PropertyType::SelectionMultiple(vec![]));
    let title_id = prop_title.id;
    let tags_id = prop_tags.id;
    let db = create_database(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_dbs(&store),
        inlines("Articles"),
        vec![prop_title, prop_tags],
    )
    .unwrap();

    let mut v1 = HashMap::new();
    v1.insert(
        title_id,
        PropertyValue::Text("Rust et WebAssembly".to_string()),
    );
    v1.insert(
        tags_id,
        PropertyValue::SelectionMultiple(vec!["tech".to_string()]),
    );

    let mut v2 = HashMap::new();
    v2.insert(
        title_id,
        PropertyValue::Text("Recette de Pâtes".to_string()),
    );
    v2.insert(
        tags_id,
        PropertyValue::SelectionMultiple(vec!["cuisine".to_string(), "tech".to_string()]),
    );

    add_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_dbs(&store),
        db.id,
        v1,
    )
    .unwrap();
    add_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_dbs(&store),
        db.id,
        v2,
    )
    .unwrap();

    // "tech" appears in the tag of both entries
    let resultats = search_entries(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_dbs(&store),
        db.id,
        "tech",
    )
    .unwrap();
    assert_eq!(resultats.len(), 2);

    // "rust" only appears in the title of the first entry
    let resultats = search_entries(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_dbs(&store),
        db.id,
        "rust",
    )
    .unwrap();
    assert_eq!(resultats.len(), 1);
}

#[test]
fn test_search_entries_aucun_resultat() {
    let store = db_store_temp();
    let prop = Property::new("Texte", PropertyType::Text);
    let prop_id = prop.id;
    let db = create_database(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_dbs(&store),
        inlines("DB"),
        vec![prop],
    )
    .unwrap();

    let mut v = HashMap::new();
    v.insert(prop_id, PropertyValue::Text("bonjour".to_string()));
    add_entry(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_dbs(&store),
        db.id,
        v,
    )
    .unwrap();

    let resultats = search_entries(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_dbs(&store),
        db.id,
        "xyzzy",
    )
    .unwrap();
    assert!(resultats.is_empty());
}
