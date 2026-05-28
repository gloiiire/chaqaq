use chaqaq::application::error::ChaqaqError;
use chaqaq::application::repository::DocumentRepository;
use chaqaq::domain::document::Document;
use chaqaq::domain::parser::parse_inline;
use chaqaq::infrastructure::json_store::JsonStore;
use std::path::PathBuf;
use uuid::Uuid;

fn dossier_temp() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("chaqaq_integ_{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn test_save_puis_load() {
    let dir = dossier_temp();
    let store = JsonStore::new(dir.clone());

    let doc = Document::new(parse_inline("Mon document"));
    store.save(&doc).unwrap();

    let charge = store.load(doc.id).unwrap();
    assert_eq!(charge.id, doc.id);

    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn test_list_retourne_toutes_les_metadonnees() {
    let dir = dossier_temp();
    let store = JsonStore::new(dir.clone());

    let doc1 = Document::new(parse_inline("Premier"));
    let doc2 = Document::new(parse_inline("Deuxième"));
    store.save(&doc1).unwrap();
    store.save(&doc2).unwrap();

    let metas = store.list().unwrap();
    assert_eq!(metas.len(), 2);

    let ids: Vec<_> = metas.iter().map(|m| m.id).collect();
    assert!(ids.contains(&doc1.id));
    assert!(ids.contains(&doc2.id));

    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn test_list_vide() {
    let dir = dossier_temp();
    let store = JsonStore::new(dir.clone());

    let metas = store.list().unwrap();
    assert!(metas.is_empty());

    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn test_load_document_inexistant() {
    let dir = dossier_temp();
    let store = JsonStore::new(dir.clone());

    let result = store.load(Uuid::new_v4());
    assert!(matches!(result, Err(ChaqaqError::NonTrouve(_))));

    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn test_save_ecrase_la_version_precedente() {
    let dir = dossier_temp();
    let store = JsonStore::new(dir.clone());

    let mut doc = Document::new(parse_inline("Titre initial"));
    store.save(&doc).unwrap();

    // on modifie le titre en mémoire et on re-sauvegarde
    doc.title = parse_inline("Titre modifié");
    store.save(&doc).unwrap();

    let charge = store.load(doc.id).unwrap();
    assert_eq!(charge.title[0].content, "Titre modifié");

    std::fs::remove_dir_all(dir).unwrap();
}
