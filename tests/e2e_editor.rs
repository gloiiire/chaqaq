/// End-to-end flow: create a leaf, edit its title via the editor,
/// save, reload, and verify the persisted state.
use pinkha::application::repository::LeafRepository;
use pinkha::application::use_cases::{create_leaf, get_leaf};
use pinkha::domain::commands::{ApplyStyle, History, Insert};
use pinkha::domain::leaf::InlineStyle;
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

    // create the leaf
    let mut doc = create_leaf(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
        "Titre",
    )
    .unwrap();

    // edit the title via the editor
    let mut state = EditorState::new(RichText::from(&doc.title));
    let mut hist = History::default();

    hist.apply(Box::new(Insert::new(5, '!')), &mut state);
    assert_eq!(state.text.content(), "Titre!");

    // write the new title back into the leaf and save
    doc.title = Vec::from(&state.text);
    store.save(&doc).unwrap();

    // reload and verify
    let recharge = get_leaf(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
        doc.id,
    )
    .unwrap();
    assert_eq!(recharge.title[0].content, "Titre!");

    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn test_style_persisté_apres_sauvegarde() {
    let (store, dir) = store_temp();

    let mut doc = create_leaf(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
        "Notes",
    )
    .unwrap();

    let mut state = EditorState::new(RichText::from(&doc.title));
    let mut hist = History::default();

    // apply Bold to "Notes"
    state.select(0..5);
    let cmd = ApplyStyle::new(&state, 0..5, InlineStyle::Bold);
    hist.apply(Box::new(cmd), &mut state);

    doc.title = Vec::from(&state.text);
    store.save(&doc).unwrap();

    let recharge = get_leaf(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
        doc.id,
    )
    .unwrap();
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

    let mut doc = create_leaf(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
        "Brouillon",
    )
    .unwrap();

    let mut state = EditorState::new(RichText::from(&doc.title));
    let mut hist = History::default();

    hist.apply(Box::new(Insert::new(9, 'X')), &mut state);
    assert_eq!(state.text.content(), "BrouillonX");

    hist.undo(&mut state);
    assert_eq!(state.text.content(), "Brouillon");

    // save the post-undo state
    doc.title = Vec::from(&state.text);
    store.save(&doc).unwrap();

    let recharge = get_leaf(
        &pinkha::infrastructure::no_op_unit_of_work::NoOpUnitOfWork::with_leaves(&store),
        doc.id,
    )
    .unwrap();
    assert_eq!(recharge.title[0].content, "Brouillon");

    std::fs::remove_dir_all(dir).unwrap();
}
