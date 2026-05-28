use uuid::Uuid;
use chaqaq::application::error::ChaqaqError;
use chaqaq::application::use_cases::{creer_document, obtenir_document, supprimer_document};
use chaqaq::application::database_use_cases::{creer_database, obtenir_database, supprimer_database};
use chaqaq::domain::database::{ProprieteType, Propriete};
use chaqaq::domain::document::InlineText;
use chaqaq::infrastructure::database_store::DatabaseStore;
use chaqaq::infrastructure::json_store::JsonStore;

fn doc_store_temp() -> JsonStore {
    let dir = std::env::temp_dir().join(format!("chaqaq_del_doc_{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    JsonStore::new(dir)
}

fn db_store_temp() -> DatabaseStore {
    let dir = std::env::temp_dir().join(format!("chaqaq_del_db_{}", Uuid::new_v4()));
    DatabaseStore::nouveau(dir).unwrap()
}

fn inlines(s: &str) -> Vec<InlineText> {
    vec![InlineText { content: s.to_string(), styles: vec![] }]
}

// ── supprimer_document ────────────────────────────────────────────────────────

#[test]
fn test_supprimer_document_existant() {
    let store = doc_store_temp();
    let doc = creer_document(&store, "À supprimer").unwrap();
    let id = doc.id;

    supprimer_document(&store, id).unwrap();

    assert!(matches!(obtenir_document(&store, id), Err(ChaqaqError::NonTrouve(_))));
}

#[test]
fn test_supprimer_document_inexistant_retourne_non_trouve() {
    let store = doc_store_temp();
    let faux_id = Uuid::new_v4();

    let result = supprimer_document(&store, faux_id);
    assert!(matches!(result, Err(ChaqaqError::NonTrouve(_))));
}

#[test]
fn test_supprimer_document_ne_supprime_pas_les_autres() {
    let store = doc_store_temp();
    let doc_a = creer_document(&store, "A").unwrap();
    let doc_b = creer_document(&store, "B").unwrap();

    supprimer_document(&store, doc_a.id).unwrap();

    assert!(matches!(obtenir_document(&store, doc_a.id), Err(ChaqaqError::NonTrouve(_))));
    assert!(obtenir_document(&store, doc_b.id).is_ok());
}

// ── supprimer_database ────────────────────────────────────────────────────────

#[test]
fn test_supprimer_database_existante() {
    let store = db_store_temp();
    let prop = Propriete::nouvelle("Titre", ProprieteType::Titre);
    let db = creer_database(&store, inlines("À supprimer"), vec![prop]).unwrap();
    let id = db.id;

    supprimer_database(&store, id).unwrap();

    assert!(matches!(obtenir_database(&store, id), Err(ChaqaqError::NonTrouve(_))));
}

#[test]
fn test_supprimer_database_inexistante_retourne_non_trouve() {
    let store = db_store_temp();
    let faux_id = Uuid::new_v4();

    let result = supprimer_database(&store, faux_id);
    assert!(matches!(result, Err(ChaqaqError::NonTrouve(_))));
}

#[test]
fn test_supprimer_database_ne_supprime_pas_les_autres() {
    let store = db_store_temp();
    let db_a = creer_database(&store, inlines("A"), vec![]).unwrap();
    let db_b = creer_database(&store, inlines("B"), vec![]).unwrap();

    supprimer_database(&store, db_a.id).unwrap();

    assert!(matches!(obtenir_database(&store, db_a.id), Err(ChaqaqError::NonTrouve(_))));
    assert!(obtenir_database(&store, db_b.id).is_ok());
}
