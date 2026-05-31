/// Teste les opérations d'édition en séquence sur un texte riche.
use pinkha::domain::commandes::{AppliquerStyle, Historique, Inserer, Supprimer};
use pinkha::domain::document::{InlineStyle, InlineText};
use pinkha::domain::editor::EditorState;
use pinkha::domain::rich_text::RichText;

fn etat_depuis(s: &str) -> EditorState {
    let inlines = vec![InlineText {
        content: s.to_string(),
        styles: vec![],
    }];
    EditorState::nouveau(RichText::from(&inlines))
}

#[test]
fn test_sequence_insertion() {
    let mut etat = etat_depuis("");
    let mut hist = Historique::default();

    for (i, ch) in "bonjour".chars().enumerate() {
        hist.appliquer(Box::new(Inserer::nouveau(i, ch)), &mut etat);
    }

    assert_eq!(etat.texte.content(), "bonjour");
    assert_eq!(etat.curseur, 7);
}

#[test]
fn test_undo_redo_multiple() {
    let mut etat = etat_depuis("");
    let mut hist = Historique::default();

    hist.appliquer(Box::new(Inserer::nouveau(0, 'a')), &mut etat);
    hist.appliquer(Box::new(Inserer::nouveau(1, 'b')), &mut etat);
    hist.appliquer(Box::new(Inserer::nouveau(2, 'c')), &mut etat);

    hist.annuler(&mut etat);
    hist.annuler(&mut etat);
    assert_eq!(etat.texte.content(), "a");

    hist.refaire(&mut etat);
    assert_eq!(etat.texte.content(), "ab");

    hist.refaire(&mut etat);
    assert_eq!(etat.texte.content(), "abc");
}

#[test]
fn test_style_et_edition_combinees() {
    let mut etat = etat_depuis("hello world");
    let mut hist = Historique::default();

    // mettre "hello" en gras
    let cmd_style = AppliquerStyle::nouveau(&etat, 0..5, InlineStyle::Bold);
    hist.appliquer(Box::new(cmd_style), &mut etat);

    // insérer un caractère dans la zone en gras
    hist.appliquer(Box::new(Inserer::nouveau(2, '!')), &mut etat);
    assert_eq!(etat.texte.content(), "he!llo world");

    // le span gras doit s'être étendu
    let retour: Vec<InlineText> = Vec::from(&etat.texte);
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
    let mut etat = EditorState::nouveau(RichText::from(&inlines));
    let mut hist = Historique::default();

    // supprime le 'g' de "gras" (position 6)
    let cmd = Supprimer::nouveau(&etat, 6).unwrap();
    hist.appliquer(Box::new(cmd), &mut etat);
    assert_eq!(etat.texte.content(), "avant ras");

    hist.annuler(&mut etat);
    assert_eq!(etat.texte.content(), "avant gras");

    let retour: Vec<InlineText> = Vec::from(&etat.texte);
    assert_eq!(retour[1].styles, vec![InlineStyle::Bold]);
}
