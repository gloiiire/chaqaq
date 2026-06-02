use pinkha::application::database_use_cases::{add_entry, create_database, search_entries};
use pinkha::application::use_cases::{create_document, search_documents};
use pinkha::domain::database::{Property, PropertyType, PropertyValue};
use pinkha::domain::document::InlineText;
use pinkha::infrastructure::database_store::DatabaseStore;
use pinkha::infrastructure::json_store::JsonStore;
use std::collections::HashMap;
use uuid::Uuid;

fn stores_temp() -> (JsonStore, DatabaseStore) {
    let id = Uuid::new_v4();
    let doc_dir = std::env::temp_dir().join(format!("pinkha_e2e_search_doc_{id}"));
    let db_dir = std::env::temp_dir().join(format!("pinkha_e2e_search_db_{id}"));
    std::fs::create_dir_all(&doc_dir).unwrap();
    (JsonStore::new(doc_dir), DatabaseStore::new(db_dir).unwrap())
}

fn inlines(s: &str) -> Vec<InlineText> {
    vec![InlineText {
        content: s.to_string(),
        styles: vec![],
    }]
}

/// Journal scenario: search across page titles AND database entries —
/// both coexist in the same result set.
#[test]
fn test_recherche_dans_journal_complet() {
    let (doc_store, db_store) = stores_temp();

    // Free-form note pages
    create_document(&doc_store, "Réflexions sur Rust").unwrap();
    create_document(&doc_store, "Recettes végétariennes").unwrap();
    create_document(&doc_store, "Notes de lecture : Rust book").unwrap();

    // Journal database with entries
    let prop = Property::new("Texte", PropertyType::Text);
    let prop_id = prop.id;
    let db = create_database(&db_store, inlines("Journal"), vec![prop]).unwrap();

    for texte in [
        "Aujourd'hui j'ai lu un article sur Rust",
        "Journée productive, gym le matin",
        "Expérience Rust : borrow checker compris !",
    ] {
        let mut v = HashMap::new();
        v.insert(prop_id, PropertyValue::Text(texte.to_string()));
        add_entry(&db_store, db.id, v).unwrap();
    }

    // Search "rust" in pages
    let pages = search_documents(&doc_store, "rust").unwrap();
    assert_eq!(pages.len(), 2); // "Réflexions sur Rust" and "Notes de lecture : Rust book"

    // Search "rust" in journal entries
    let entries = search_entries(&db_store, db.id, "rust").unwrap();
    assert_eq!(entries.len(), 2);
}

/// An empty query returns everything (show-all behaviour).
#[test]
fn test_recherche_vide_retourne_tout() {
    let (doc_store, db_store) = stores_temp();

    create_document(&doc_store, "A").unwrap();
    create_document(&doc_store, "B").unwrap();
    create_document(&doc_store, "C").unwrap();

    let prop = Property::new("X", PropertyType::Text);
    let prop_id = prop.id;
    let db = create_database(&db_store, inlines("DB"), vec![prop]).unwrap();
    for t in ["un", "deux"] {
        let mut v = HashMap::new();
        v.insert(prop_id, PropertyValue::Text(t.to_string()));
        add_entry(&db_store, db.id, v).unwrap();
    }

    assert_eq!(search_documents(&doc_store, "").unwrap().len(), 3);
    assert_eq!(search_entries(&db_store, db.id, "").unwrap().len(), 2);
}

/// Search across a database with mixed property types.
#[test]
fn test_recherche_entries_selection_et_texte() {
    let (_doc_store, db_store) = stores_temp();

    let prop_statut = Property::new(
        "Statut",
        PropertyType::Selection(vec!["Brouillon".into(), "Publié".into()]),
    );
    let prop_title = Property::new("Titre", PropertyType::Text);
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
            PropertyValue::Selection(Some(statut.to_string())),
        );
        v.insert(title_id, PropertyValue::Text(title.to_string()));
        add_entry(&db_store, db.id, v).unwrap();
    }

    // "brouillon" matches the 2 draft articles (via the Statut column)
    let brouillons = search_entries(&db_store, db.id, "brouillon").unwrap();
    assert_eq!(brouillons.len(), 2);

    // "rust" only matches in the title of the second article
    let rust = search_entries(&db_store, db.id, "rust").unwrap();
    assert_eq!(rust.len(), 1);
}
