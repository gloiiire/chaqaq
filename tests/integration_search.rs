use std::collections::HashMap;
use uuid::Uuid;
use chaqaq::application::database_use_cases::{ajouter_entree, creer_database, rechercher_entrees};
use chaqaq::application::use_cases::{creer_document, rechercher_documents};
use chaqaq::domain::database::{ProprieteType, Propriete, ValeurPropriete};
use chaqaq::domain::document::InlineText;
use chaqaq::infrastructure::database_store::DatabaseStore;
use chaqaq::infrastructure::json_store::JsonStore;

fn doc_store_temp() -> JsonStore {
    let dir = std::env::temp_dir().join(format!("chaqaq_search_doc_{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    JsonStore::new(dir)
}

fn db_store_temp() -> DatabaseStore {
    let dir = std::env::temp_dir().join(format!("chaqaq_search_db_{}", Uuid::new_v4()));
    DatabaseStore::nouveau(dir).unwrap()
}

fn inlines(s: &str) -> Vec<InlineText> {
    vec![InlineText { content: s.to_string(), styles: vec![] }]
}

// ── Recherche documents ───────────────────────────────────────────────────────

#[test]
fn test_rechercher_documents_par_titre() {
    let store = doc_store_temp();
    creer_document(&store, "Journal de voyage").unwrap();
    creer_document(&store, "Recettes de cuisine").unwrap();
    creer_document(&store, "Journal personnel").unwrap();

    let resultats = rechercher_documents(&store, "journal").unwrap();
    assert_eq!(resultats.len(), 2);
}

#[test]
fn test_rechercher_documents_insensible_casse() {
    let store = doc_store_temp();
    creer_document(&store, "Notes de Réunion").unwrap();
    creer_document(&store, "Todo list").unwrap();

    let resultats = rechercher_documents(&store, "NOTES").unwrap();
    assert_eq!(resultats.len(), 1);
}

#[test]
fn test_rechercher_documents_aucun_resultat() {
    let store = doc_store_temp();
    creer_document(&store, "Journal").unwrap();

    let resultats = rechercher_documents(&store, "xyzzy").unwrap();
    assert!(resultats.is_empty());
}

#[test]
fn test_rechercher_documents_query_vide_retourne_tout() {
    let store = doc_store_temp();
    creer_document(&store, "Doc A").unwrap();
    creer_document(&store, "Doc B").unwrap();

    let resultats = rechercher_documents(&store, "").unwrap();
    assert_eq!(resultats.len(), 2);
}

// ── Recherche entrées database ────────────────────────────────────────────────

#[test]
fn test_rechercher_entrees_par_texte() {
    let store = db_store_temp();
    let prop = Propriete::nouvelle("Contenu", ProprieteType::Texte);
    let prop_id = prop.id;
    let db = creer_database(&store, inlines("Notes"), vec![prop]).unwrap();

    for texte in ["Première pensée", "Deuxième réflexion", "Troisième pensée"] {
        let mut v = HashMap::new();
        v.insert(prop_id, ValeurPropriete::Texte(texte.to_string()));
        ajouter_entree(&store, db.id, v).unwrap();
    }

    let resultats = rechercher_entrees(&store, db.id, "pensée").unwrap();
    assert_eq!(resultats.len(), 2);
}

#[test]
fn test_rechercher_entrees_insensible_casse() {
    let store = db_store_temp();
    let prop = Propriete::nouvelle("Titre", ProprieteType::Texte);
    let prop_id = prop.id;
    let db = creer_database(&store, inlines("DB"), vec![prop]).unwrap();

    let mut v = HashMap::new();
    v.insert(prop_id, ValeurPropriete::Texte("Vacances d'Été".to_string()));
    ajouter_entree(&store, db.id, v).unwrap();

    let resultats = rechercher_entrees(&store, db.id, "été").unwrap();
    assert_eq!(resultats.len(), 1);
}

#[test]
fn test_rechercher_entrees_multi_champs() {
    let store = db_store_temp();
    let prop_titre  = Propriete::nouvelle("Titre",  ProprieteType::Texte);
    let prop_tags   = Propriete::nouvelle("Tags",   ProprieteType::SelectionMultiple(vec![]));
    let titre_id = prop_titre.id;
    let tags_id  = prop_tags.id;
    let db = creer_database(&store, inlines("Articles"), vec![prop_titre, prop_tags]).unwrap();

    let mut v1 = HashMap::new();
    v1.insert(titre_id, ValeurPropriete::Texte("Rust et WebAssembly".to_string()));
    v1.insert(tags_id,  ValeurPropriete::SelectionMultiple(vec!["tech".to_string()]));

    let mut v2 = HashMap::new();
    v2.insert(titre_id, ValeurPropriete::Texte("Recette de Pâtes".to_string()));
    v2.insert(tags_id,  ValeurPropriete::SelectionMultiple(vec!["cuisine".to_string(), "tech".to_string()]));

    ajouter_entree(&store, db.id, v1).unwrap();
    ajouter_entree(&store, db.id, v2).unwrap();

    // "tech" apparaît dans le tag des deux entrées
    let resultats = rechercher_entrees(&store, db.id, "tech").unwrap();
    assert_eq!(resultats.len(), 2);

    // "rust" n'est que dans le titre de la première
    let resultats = rechercher_entrees(&store, db.id, "rust").unwrap();
    assert_eq!(resultats.len(), 1);
}

#[test]
fn test_rechercher_entrees_aucun_resultat() {
    let store = db_store_temp();
    let prop = Propriete::nouvelle("Texte", ProprieteType::Texte);
    let prop_id = prop.id;
    let db = creer_database(&store, inlines("DB"), vec![prop]).unwrap();

    let mut v = HashMap::new();
    v.insert(prop_id, ValeurPropriete::Texte("bonjour".to_string()));
    ajouter_entree(&store, db.id, v).unwrap();

    let resultats = rechercher_entrees(&store, db.id, "xyzzy").unwrap();
    assert!(resultats.is_empty());
}
