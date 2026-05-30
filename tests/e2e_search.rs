use chaqaq::application::database_use_cases::{add_entry, create_database, search_entries};
use chaqaq::application::use_cases::{create_document, search_documents};
use chaqaq::domain::database::{Propriete, ProprieteType, ValeurPropriete};
use chaqaq::domain::document::InlineText;
use chaqaq::infrastructure::database_store::DatabaseStore;
use chaqaq::infrastructure::json_store::JsonStore;
use std::collections::HashMap;
use uuid::Uuid;

fn stores_temp() -> (JsonStore, DatabaseStore) {
    let id = Uuid::new_v4();
    let doc_dir = std::env::temp_dir().join(format!("chaqaq_e2e_search_doc_{id}"));
    let db_dir = std::env::temp_dir().join(format!("chaqaq_e2e_search_db_{id}"));
    std::fs::create_dir_all(&doc_dir).unwrap();
    (
        JsonStore::new(doc_dir),
        DatabaseStore::nouveau(db_dir).unwrap(),
    )
}

fn inlines(s: &str) -> Vec<InlineText> {
    vec![InlineText {
        content: s.to_string(),
        styles: vec![],
    }]
}

/// Scénario journal : rechercher dans les titles de pages ET dans les entrées
/// de la database journal — les deux coexistent.
#[test]
fn test_recherche_dans_journal_complet() {
    let (doc_store, db_store) = stores_temp();

    // Pages de notes libres
    create_document(&doc_store, "Réflexions sur Rust").unwrap();
    create_document(&doc_store, "Recettes végétariennes").unwrap();
    create_document(&doc_store, "Notes de lecture : Rust book").unwrap();

    // Database journal avec entrées
    let prop = Propriete::nouvelle("Texte", ProprieteType::Texte);
    let prop_id = prop.id;
    let db = create_database(&db_store, inlines("Journal"), vec![prop]).unwrap();

    for texte in [
        "Aujourd'hui j'ai lu un article sur Rust",
        "Journée productive, gym le matin",
        "Expérience Rust : borrow checker compris !",
    ] {
        let mut v = HashMap::new();
        v.insert(prop_id, ValeurPropriete::Texte(texte.to_string()));
        add_entry(&db_store, db.id, v).unwrap();
    }

    // Recherche "rust" dans les pages
    let pages = search_documents(&doc_store, "rust").unwrap();
    assert_eq!(pages.len(), 2); // "Réflexions sur Rust" et "Notes de lecture : Rust book"

    // Recherche "rust" dans les entrées journal
    let entrees = search_entries(&db_store, db.id, "rust").unwrap();
    assert_eq!(entrees.len(), 2);
}

/// Vérifie qu'une recherche vide retourne tout (comportement "voir tout").
#[test]
fn test_recherche_vide_retourne_tout() {
    let (doc_store, db_store) = stores_temp();

    create_document(&doc_store, "A").unwrap();
    create_document(&doc_store, "B").unwrap();
    create_document(&doc_store, "C").unwrap();

    let prop = Propriete::nouvelle("X", ProprieteType::Texte);
    let prop_id = prop.id;
    let db = create_database(&db_store, inlines("DB"), vec![prop]).unwrap();
    for t in ["un", "deux"] {
        let mut v = HashMap::new();
        v.insert(prop_id, ValeurPropriete::Texte(t.to_string()));
        add_entry(&db_store, db.id, v).unwrap();
    }

    assert_eq!(search_documents(&doc_store, "").unwrap().len(), 3);
    assert_eq!(search_entries(&db_store, db.id, "").unwrap().len(), 2);
}

/// Recherche dans une database avec plusieurs types de propriétés.
#[test]
fn test_recherche_entrees_selection_et_texte() {
    let (_doc_store, db_store) = stores_temp();

    let prop_statut = Propriete::nouvelle(
        "Statut",
        ProprieteType::Selection(vec!["Brouillon".into(), "Publié".into()]),
    );
    let prop_title = Propriete::nouvelle("Titre", ProprieteType::Texte);
    let statut_id = prop_statut.id;
    let title_id = prop_title.id;

    let db = create_database(
        &db_store,
        inlines("Articles"),
        vec![prop_statut, prop_title],
    )
    .unwrap();

    let articles = [
        ("Brouillon", "Premier jet de l'article"),
        ("Publié", "Guide complet Rust"),
        ("Brouillon", "Idées pour plus tard"),
    ];
    for (statut, title) in articles {
        let mut v = HashMap::new();
        v.insert(
            statut_id,
            ValeurPropriete::Selection(Some(statut.to_string())),
        );
        v.insert(title_id, ValeurPropriete::Texte(title.to_string()));
        add_entry(&db_store, db.id, v).unwrap();
    }

    // "brouillon" matche les 2 articles en brouillon (via la colonne Statut)
    let brouillons = search_entries(&db_store, db.id, "brouillon").unwrap();
    assert_eq!(brouillons.len(), 2);

    // "rust" ne matche que dans le title du second
    let rust = search_entries(&db_store, db.id, "rust").unwrap();
    assert_eq!(rust.len(), 1);
}
