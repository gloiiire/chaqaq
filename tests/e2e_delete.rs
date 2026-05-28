use chaqaq::application::database_use_cases::{
    ajouter_entree, creer_database, lister_databases, obtenir_database, supprimer_database,
};
use chaqaq::application::error::ChaqaqError;
use chaqaq::application::use_cases::{
    ajouter_bloc, creer_document, lister_documents, obtenir_document, supprimer_document,
};
use chaqaq::domain::database::{Propriete, ProprieteType, ValeurPropriete};
use chaqaq::domain::document::{BlockContent, InlineText};
use chaqaq::infrastructure::database_store::DatabaseStore;
use chaqaq::infrastructure::json_store::JsonStore;
use std::collections::HashMap;
use uuid::Uuid;

fn doc_store_temp() -> JsonStore {
    let dir = std::env::temp_dir().join(format!("chaqaq_e2e_del_doc_{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    JsonStore::new(dir)
}

fn db_store_temp() -> DatabaseStore {
    let dir = std::env::temp_dir().join(format!("chaqaq_e2e_del_db_{}", Uuid::new_v4()));
    DatabaseStore::nouveau(dir).unwrap()
}

fn inlines(s: &str) -> Vec<InlineText> {
    vec![InlineText {
        content: s.to_string(),
        styles: vec![],
    }]
}

/// Crée plusieurs documents, en supprime un, vérifie la liste et l'inaccessibilité.
#[test]
fn test_flux_suppression_document() {
    let store = doc_store_temp();

    let doc_a = creer_document(&store, "Projet Alpha").unwrap();
    let doc_b = creer_document(&store, "Projet Beta").unwrap();
    let doc_c = creer_document(&store, "Projet Gamma").unwrap();

    // Ajoute des blocs à A pour s'assurer que supprimer A ne touche pas B/C
    ajouter_bloc(
        &store,
        doc_a.id,
        BlockContent::Text(inlines("Note interne")),
    )
    .unwrap();

    supprimer_document(&store, doc_b.id).unwrap();

    // B est inaccessible
    assert!(matches!(
        obtenir_document(&store, doc_b.id),
        Err(ChaqaqError::NonTrouve(_))
    ));

    // A et C sont intacts
    let a = obtenir_document(&store, doc_a.id).unwrap();
    assert_eq!(a.blocks.len(), 1);
    assert!(obtenir_document(&store, doc_c.id).is_ok());

    // La liste ne contient plus B
    let liste = lister_documents(&store).unwrap();
    assert_eq!(liste.len(), 2);
    assert!(!liste.iter().any(|m| m.id == doc_b.id));
}

/// Crée une database avec des entrées, la supprime, vérifie l'inaccessibilité.
#[test]
fn test_flux_suppression_database() {
    let store = db_store_temp();

    let prop = Propriete::nouvelle("Nom", ProprieteType::Texte);
    let prop_id = prop.id;

    let db_a = creer_database(&store, inlines("Archive"), vec![prop]).unwrap();
    let db_b = creer_database(&store, inlines("Active"), vec![]).unwrap();

    // Ajoute une entrée à Archive
    let mut v = HashMap::new();
    v.insert(prop_id, ValeurPropriete::Texte("Ancienne note".to_string()));
    ajouter_entree(&store, db_a.id, v).unwrap();

    supprimer_database(&store, db_a.id).unwrap();

    // Archive est inaccessible
    assert!(matches!(
        obtenir_database(&store, db_a.id),
        Err(ChaqaqError::NonTrouve(_))
    ));

    // Active reste intacte
    assert!(obtenir_database(&store, db_b.id).is_ok());

    // La liste ne contient plus Archive
    let liste = lister_databases(&store).unwrap();
    assert_eq!(liste.len(), 1);
    assert_eq!(liste[0].id, db_b.id);
}

/// Double suppression retourne NonTrouve la deuxième fois.
#[test]
fn test_double_suppression_retourne_erreur() {
    let store = doc_store_temp();
    let doc = creer_document(&store, "Unique").unwrap();

    supprimer_document(&store, doc.id).unwrap();
    let result = supprimer_document(&store, doc.id);
    assert!(matches!(result, Err(ChaqaqError::NonTrouve(_))));
}
