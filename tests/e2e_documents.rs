use pinkha::application::error::PinkhaError;
use pinkha::application::use_cases::{add_block, create_document, get_document, list_documents};
use pinkha::domain::document::BlockContent;
use pinkha::domain::parser::parse_inline;
use pinkha::infrastructure::json_store::JsonStore;
use std::path::PathBuf;
use uuid::Uuid;

fn store_temp() -> (JsonStore, PathBuf) {
    let dir = std::env::temp_dir().join(format!("pinkha_e2e_{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    (JsonStore::new(dir.clone()), dir)
}

#[test]
fn test_creer_puis_obtenir() {
    let (store, dir) = store_temp();

    let doc = create_document(&store, "Mon title").unwrap();
    let obtenu = get_document(&store, doc.id).unwrap();

    assert_eq!(doc.id, obtenu.id);
    assert_eq!(obtenu.title[0].content, "Mon title");

    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn test_flux_complet() {
    let (store, dir) = store_temp();

    // création
    let doc = create_document(&store, "Journal").unwrap();

    // listing : 1 document, bon id
    let liste = list_documents(&store).unwrap();
    assert_eq!(liste.len(), 1);
    assert_eq!(liste[0].id, doc.id);

    // ajout d'un bloc
    let mis_a_jour = add_block(
        &store,
        doc.id,
        BlockContent::Text(parse_inline("Premier bloc")),
    )
    .unwrap();
    assert_eq!(mis_a_jour.blocks.len(), 1);

    // rechargement : le bloc est bien persisté
    let recharge = get_document(&store, doc.id).unwrap();
    assert_eq!(recharge.blocks.len(), 1);

    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn test_lister_plusieurs_documents() {
    let (store, dir) = store_temp();

    create_document(&store, "Alpha").unwrap();
    create_document(&store, "Beta").unwrap();
    create_document(&store, "Gamma").unwrap();

    let liste = list_documents(&store).unwrap();
    assert_eq!(liste.len(), 3);

    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn test_get_document_inexistant() {
    let (store, dir) = store_temp();

    let result = get_document(&store, Uuid::new_v4());
    assert!(matches!(result, Err(PinkhaError::NotFound(_))));

    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn test_ajouter_plusieurs_blocs() {
    let (store, dir) = store_temp();

    let doc = create_document(&store, "Notes").unwrap();

    add_block(&store, doc.id, BlockContent::Text(parse_inline("Bloc 1"))).unwrap();
    add_block(
        &store,
        doc.id,
        BlockContent::Heading {
            text: parse_inline("Titre"),
            level: 1,
        },
    )
    .unwrap();
    add_block(&store, doc.id, BlockContent::Divider).unwrap();

    let recharge = get_document(&store, doc.id).unwrap();
    assert_eq!(recharge.blocks.len(), 3);

    std::fs::remove_dir_all(dir).unwrap();
}
