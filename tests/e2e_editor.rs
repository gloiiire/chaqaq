/// Flux complet : création d'un document → édition du title avec l'éditeur
/// → sauvegarde → rechargement → vérification.
use pinkha::application::repository::DocumentRepository;
use pinkha::application::use_cases::{create_document, get_document};
use pinkha::domain::commandes::{ApplyStyle, History, Insert};
use pinkha::domain::document::InlineStyle;
use pinkha::domain::editor::EditorState;
use pinkha::domain::rich_text::RichText;
use pinkha::infrastructure::json_store::JsonStore;
use std::path::PathBuf;
use uuid::Uuid;

fn store_temp() -> (JsonStore, PathBuf) {
    let dir = std::env::temp_dir().join(format!("pinkha_e2e_editor_{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    (JsonStore::new(dir.clone()), dir)
}

#[test]
fn test_editer_title_puis_sauvegarder() {
    let (store, dir) = store_temp();

    // création du document
    let mut doc = create_document(&store, "Titre").unwrap();

    // édition du title via l'éditeur
    let mut state = EditorState::new(RichText::from(&doc.title));
    let mut hist = History::default();

    hist.apply(Box::new(Insert::new(5, '!')), &mut state);
    assert_eq!(state.text.content(), "Titre!");

    // on réécrit le title dans le document et on sauvegarde
    doc.title = Vec::from(&state.text);
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

    let mut state = EditorState::new(RichText::from(&doc.title));
    let mut hist = History::default();

    // mettre "Notes" en gras
    state.select(0..5);
    let cmd = ApplyStyle::new(&state, 0..5, InlineStyle::Bold);
    hist.apply(Box::new(cmd), &mut state);

    doc.title = Vec::from(&state.text);
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

    let mut state = EditorState::new(RichText::from(&doc.title));
    let mut hist = History::default();

    hist.apply(Box::new(Insert::new(9, 'X')), &mut state);
    assert_eq!(state.text.content(), "BrouillonX");

    hist.undo(&mut state);
    assert_eq!(state.text.content(), "Brouillon");

    // sauvegarde de l'état après undo
    doc.title = Vec::from(&state.text);
    store.save(&doc).unwrap();

    let recharge = get_document(&store, doc.id).unwrap();
    assert_eq!(recharge.title[0].content, "Brouillon");

    std::fs::remove_dir_all(dir).unwrap();
}
