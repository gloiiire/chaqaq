/// Integration tests for rich-text editing operations performed in sequence.
use pinkha::domain::commands::{ApplyStyle, Delete, History, Insert};
use pinkha::domain::document::{InlineStyle, InlineText};
use pinkha::domain::editor::EditorState;
use pinkha::domain::rich_text::RichText;

fn state_from(s: &str) -> EditorState {
    let inlines = vec![InlineText {
        content: s.to_string(),
        styles: vec![],
    }];
    EditorState::new(RichText::from(&inlines))
}

#[test]
fn test_sequence_insertion() {
    let mut state = state_from("");
    let mut hist = History::default();

    for (i, ch) in "bonjour".chars().enumerate() {
        hist.apply(Box::new(Insert::new(i, ch)), &mut state);
    }

    assert_eq!(state.text.content(), "bonjour");
    assert_eq!(state.cursor, 7);
}

#[test]
fn test_undo_redo_multiple() {
    let mut state = state_from("");
    let mut hist = History::default();

    hist.apply(Box::new(Insert::new(0, 'a')), &mut state);
    hist.apply(Box::new(Insert::new(1, 'b')), &mut state);
    hist.apply(Box::new(Insert::new(2, 'c')), &mut state);

    hist.undo(&mut state);
    hist.undo(&mut state);
    assert_eq!(state.text.content(), "a");

    hist.redo(&mut state);
    assert_eq!(state.text.content(), "ab");

    hist.redo(&mut state);
    assert_eq!(state.text.content(), "abc");
}

#[test]
fn test_style_et_edition_combinees() {
    let mut state = state_from("hello world");
    let mut hist = History::default();

    // apply Bold to "hello"
    let cmd_style = ApplyStyle::new(&state, 0..5, InlineStyle::Bold);
    hist.apply(Box::new(cmd_style), &mut state);

    // insert a character inside the bold range
    hist.apply(Box::new(Insert::new(2, '!')), &mut state);
    assert_eq!(state.text.content(), "he!llo world");

    // the bold span must have expanded to cover the inserted character
    let retour: Vec<InlineText> = Vec::from(&state.text);
    assert_eq!(retour[0].styles, vec![InlineStyle::Bold]);
    assert_eq!(retour[0].content, "he!llo");
}

#[test]
fn test_supprimer_dans_texte_style() {
    let inlines = vec![
        InlineText {
            content: "avant ".to_string(),
            styles: vec![],
        },
        InlineText {
            content: "gras".to_string(),
            styles: vec![InlineStyle::Bold],
        },
    ];
    let mut state = EditorState::new(RichText::from(&inlines));
    let mut hist = History::default();

    // delete the 'g' of "gras" (position 6)
    let cmd = Delete::new(&state, 6).unwrap();
    hist.apply(Box::new(cmd), &mut state);
    assert_eq!(state.text.content(), "avant ras");

    hist.undo(&mut state);
    assert_eq!(state.text.content(), "avant gras");

    let retour: Vec<InlineText> = Vec::from(&state.text);
    assert_eq!(retour[1].styles, vec![InlineStyle::Bold]);
}
