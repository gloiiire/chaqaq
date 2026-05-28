use chaqaq::application::error::ChaqaqError;
use chaqaq::application::use_cases::{
    ajouter_bloc, creer_document, lister_documents, obtenir_document,
};
use chaqaq::domain::document::BlockContent;
use chaqaq::domain::parser::parse_inline;
use chaqaq::infrastructure::json_store::JsonStore;
use std::path::PathBuf;
use uuid::Uuid;

fn store_temp() -> (JsonStore, PathBuf) {
    let dir = std::env::temp_dir().join(format!("chaqaq_e2e_{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    (JsonStore::new(dir.clone()), dir)
}

#[test]
fn test_creer_puis_obtenir() {
    let (store, dir) = store_temp();

    let doc = creer_document(&store, "Mon titre").unwrap();
    let obtenu = obtenir_document(&store, doc.id).unwrap();

    assert_eq!(doc.id, obtenu.id);
    assert_eq!(obtenu.title[0].content, "Mon titre");

    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn test_flux_complet() {
    let (store, dir) = store_temp();

    // création
    let doc = creer_document(&store, "Journal").unwrap();

    // listing : 1 document, bon id
    let liste = lister_documents(&store).unwrap();
    assert_eq!(liste.len(), 1);
    assert_eq!(liste[0].id, doc.id);

    // ajout d'un bloc
    let mis_a_jour = ajouter_bloc(
        &store,
        doc.id,
        BlockContent::Text(parse_inline("Premier bloc")),
    )
    .unwrap();
    assert_eq!(mis_a_jour.blocks.len(), 1);

    // rechargement : le bloc est bien persisté
    let recharge = obtenir_document(&store, doc.id).unwrap();
    assert_eq!(recharge.blocks.len(), 1);

    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn test_lister_plusieurs_documents() {
    let (store, dir) = store_temp();

    creer_document(&store, "Alpha").unwrap();
    creer_document(&store, "Beta").unwrap();
    creer_document(&store, "Gamma").unwrap();

    let liste = lister_documents(&store).unwrap();
    assert_eq!(liste.len(), 3);

    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn test_obtenir_document_inexistant() {
    let (store, dir) = store_temp();

    let result = obtenir_document(&store, Uuid::new_v4());
    assert!(matches!(result, Err(ChaqaqError::NonTrouve(_))));

    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn test_ajouter_plusieurs_blocs() {
    let (store, dir) = store_temp();

    let doc = creer_document(&store, "Notes").unwrap();

    ajouter_bloc(&store, doc.id, BlockContent::Text(parse_inline("Bloc 1"))).unwrap();
    ajouter_bloc(
        &store,
        doc.id,
        BlockContent::Heading {
            text: parse_inline("Titre"),
            level: 1,
        },
    )
    .unwrap();
    ajouter_bloc(&store, doc.id, BlockContent::Divider).unwrap();

    let recharge = obtenir_document(&store, doc.id).unwrap();
    assert_eq!(recharge.blocks.len(), 3);

    std::fs::remove_dir_all(dir).unwrap();
}
