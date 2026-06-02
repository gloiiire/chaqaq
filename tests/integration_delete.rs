use pinkha::application::database_use_cases::{create_database, delete_database, get_database};
use pinkha::application::error::PinkhaError;
use pinkha::application::use_cases::{create_document, delete_document, get_document};
use pinkha::domain::database::{Property, PropertyType};
use pinkha::domain::document::InlineText;
use pinkha::infrastructure::database_store::DatabaseStore;
use pinkha::infrastructure::json_store::JsonStore;
use uuid::Uuid;

fn doc_store_temp() -> JsonStore {
    let dir = std::env::temp_dir().join(format!("pinkha_del_doc_{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    JsonStore::new(dir)
}

fn db_store_temp() -> DatabaseStore {
    let dir = std::env::temp_dir().join(format!("pinkha_del_db_{}", Uuid::new_v4()));
    DatabaseStore::new(dir).unwrap()
}

fn inlines(s: &str) -> Vec<InlineText> {
    vec![InlineText {
        content: s.to_string(),
        styles: vec![],
    }]
}

// ── delete_document ────────────────────────────────────────────────────────

#[test]
fn test_delete_document_existant() {
    let store = doc_store_temp();
    let doc = create_document(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_docs(&store),
        "À supprimer",
    )
    .unwrap();
    let id = doc.id;

    delete_document(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_docs(&store),
        id,
    )
    .unwrap();

    assert!(matches!(
        get_document(
            &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_docs(&store),
            id
        ),
        Err(PinkhaError::NotFound(_))
    ));
}

#[test]
fn test_delete_document_inexistant_retourne_non_trouve() {
    let store = doc_store_temp();
    let faux_id = Uuid::new_v4();

    let result = delete_document(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_docs(&store),
        faux_id,
    );
    assert!(matches!(result, Err(PinkhaError::NotFound(_))));
}

#[test]
fn test_delete_document_ne_supprime_pas_les_autres() {
    let store = doc_store_temp();
    let doc_a = create_document(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_docs(&store),
        "A",
    )
    .unwrap();
    let doc_b = create_document(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_docs(&store),
        "B",
    )
    .unwrap();

    delete_document(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_docs(&store),
        doc_a.id,
    )
    .unwrap();

    assert!(matches!(
        get_document(
            &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_docs(&store),
            doc_a.id
        ),
        Err(PinkhaError::NotFound(_))
    ));
    assert!(
        get_document(
            &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_docs(&store),
            doc_b.id
        )
        .is_ok()
    );
}

// ── delete_database ────────────────────────────────────────────────────────

#[test]
fn test_delete_database_existante() {
    let store = db_store_temp();
    let prop = Property::new("Titre", PropertyType::Title);
    let db = create_database(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_dbs(&store),
        inlines("À supprimer"),
        vec![prop],
    )
    .unwrap();
    let id = db.id;

    delete_database(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_dbs(&store),
        id,
    )
    .unwrap();

    assert!(matches!(
        get_database(
            &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_dbs(&store),
            id
        ),
        Err(PinkhaError::NotFound(_))
    ));
}

#[test]
fn test_delete_database_inexistante_retourne_non_trouve() {
    let store = db_store_temp();
    let faux_id = Uuid::new_v4();

    let result = delete_database(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_dbs(&store),
        faux_id,
    );
    assert!(matches!(result, Err(PinkhaError::NotFound(_))));
}

#[test]
fn test_delete_database_ne_supprime_pas_les_autres() {
    let store = db_store_temp();
    let db_a = create_database(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_dbs(&store),
        inlines("A"),
        vec![],
    )
    .unwrap();
    let db_b = create_database(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_dbs(&store),
        inlines("B"),
        vec![],
    )
    .unwrap();

    delete_database(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_dbs(&store),
        db_a.id,
    )
    .unwrap();

    assert!(matches!(
        get_database(
            &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_dbs(&store),
            db_a.id
        ),
        Err(PinkhaError::NotFound(_))
    ));
    assert!(
        get_database(
            &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_dbs(&store),
            db_b.id
        )
        .is_ok()
    );
}
