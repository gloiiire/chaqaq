/// Flux complet : création d'un document → édition du title avec l'éditeur
/// → sauvegarde → rechargement → vérification.
use chaqaq::application::repository::DocumentRepository;
use chaqaq::application::use_cases::{create_document, get_document};
use chaqaq::domain::commandes::{AppliquerStyle, Historique, Inserer};
use chaqaq::domain::document::InlineStyle;
use chaqaq::domain::editor::EditorState;
use chaqaq::domain::rich_text::RichText;
use chaqaq::infrastructure::json_store::JsonStore;
use std::path::PathBuf;
use uuid::Uuid;

fn store_temp() -> (JsonStore, PathBuf) {
    let dir = std::env::temp_dir().join(format!("chaqaq_e2e_editor_{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    (JsonStore::new(dir.clone()), dir)
}

#[test]
fn test_editer_title_puis_sauvegarder() {
    let (store, dir) = store_temp();

    // création du document
    let mut doc = create_document(&store, "Titre").unwrap();

    // édition du title via l'éditeur
    let mut etat = EditorState::nouveau(RichText::from(&doc.title));
    let mut hist = Historique::default();

    hist.appliquer(Box::new(Inserer::nouveau(5, '!')), &mut etat);
    assert_eq!(etat.texte.content(), "Titre!");

    // on réécrit le title dans le document et on sauvegarde
    doc.title = Vec::from(&etat.texte);
    store.save(&doc).unwrap();

    // rechargement et vérification
    let recharge = get_document(&store, doc.id).unwrap();
    assert_eq!(recharge.title[0].content, "Titre!");

    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn test_style_persisté_apres_sauvegarde() {
    let (store, dir) = store_temp();

    let mut doc = create_document(&store, "Notes").unwrap();

    let mut etat = EditorState::nouveau(RichText::from(&doc.title));
    let mut hist = Historique::default();

    // mettre "Notes" en gras
    etat.selectionner(0..5);
    let cmd = AppliquerStyle::nouveau(&etat, 0..5, InlineStyle::Bold);
    hist.appliquer(Box::new(cmd), &mut etat);

    doc.title = Vec::from(&etat.texte);
    store.save(&doc).unwrap();

    let recharge = get_document(&store, doc.id).unwrap();
    assert!(
        recharge
            .title
            .iter()
            .any(|t| t.styles.contains(&InlineStyle::Bold))
    );

    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn test_undo_avant_sauvegarde() {
    let (store, dir) = store_temp();

    let mut doc = create_document(&store, "Brouillon").unwrap();

    let mut etat = EditorState::nouveau(RichText::from(&doc.title));
    let mut hist = Historique::default();

    hist.appliquer(Box::new(Inserer::nouveau(9, 'X')), &mut etat);
    assert_eq!(etat.texte.content(), "BrouillonX");

    hist.annuler(&mut etat);
    assert_eq!(etat.texte.content(), "Brouillon");

    // sauvegarde de l'état après undo
    doc.title = Vec::from(&etat.texte);
    store.save(&doc).unwrap();

    let recharge = get_document(&store, doc.id).unwrap();
    assert_eq!(recharge.title[0].content, "Brouillon");

    std::fs::remove_dir_all(dir).unwrap();
}
