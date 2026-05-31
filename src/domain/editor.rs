#![allow(dead_code)]
use crate::domain::document::InlineStyle;
use crate::domain::rich_text::RichText;
use std::ops::Range;

pub struct EditorState {
    pub text: RichText,
    pub cursor: usize,
    pub selection: Option<Range<usize>>,
}

impl EditorState {
    pub fn new(text: RichText) -> Self {
        let cursor = text.length();
        Self {
            text,
            cursor,
            selection: None,
        }
    }

    pub fn insert(&mut self, ch: char) {
        self.text.insert_char(self.cursor, ch);
        self.cursor += 1;
        self.selection = None;
    }

    /// Supprime le char avant le curseur (Backspace).
    pub fn delete_before(&mut self) {
        if self.cursor == 0 {
            return;
        }
        self.cursor -= 1;
        self.text.delete_char(self.cursor);
        self.selection = None;
    }

    /// Supprime le char après le curseur (Delete).
    pub fn delete_after(&mut self) {
        self.text.delete_char(self.cursor);
        self.selection = None;
    }

    pub fn move_left(&mut self) {
        if self.cursor > 0 {
            self.cursor -= 1;
        }
        self.selection = None;
    }

    pub fn move_right(&mut self) {
        if self.cursor < self.text.length() {
            self.cursor += 1;
        }
        self.selection = None;
    }

    pub fn go_to_start(&mut self) {
        self.cursor = 0;
        self.selection = None;
    }

    pub fn go_to_end(&mut self) {
        self.cursor = self.text.length();
        self.selection = None;
    }

    pub fn select(&mut self, range: Range<usize>) {
        self.selection = Some(range);
    }

    /// Bascule le style sur la sélection courante.
    pub fn toggle_style(&mut self, style: InlineStyle) {
        if let Some(range) = self.selection.clone() {
            self.text.toggle_style(range, style);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::document::InlineStyle;
    use crate::domain::document::InlineText;
    use crate::domain::rich_text::RichText;

    fn state_from(s: &str) -> EditorState {
        let inlines = vec![InlineText {
            content: s.to_string(),
            styles: vec![],
        }];
        EditorState::new(RichText::from(&inlines))
    }

    #[test]
    fn test_inserer_avance_curseur() {
        let mut state = state_from("ab");
        state.cursor = 1;
        state.insert('X');
        assert_eq!(state.text.content(), "aXb");
        assert_eq!(state.cursor, 2);
    }

    #[test]
    fn test_supprimer_avant_recule_curseur() {
        let mut state = state_from("abc");
        state.cursor = 2;
        state.delete_before();
        assert_eq!(state.text.content(), "ac");
        assert_eq!(state.cursor, 1);
    }

    #[test]
    fn test_supprimer_avant_en_debut_ne_fait_rien() {
        let mut state = state_from("abc");
        state.cursor = 0;
        state.delete_before();
        assert_eq!(state.text.content(), "abc");
        assert_eq!(state.cursor, 0);
    }

    #[test]
    fn test_supprimer_apres_ne_bouge_pas_curseur() {
        let mut state = state_from("abc");
        state.cursor = 1;
        state.delete_after();
        assert_eq!(state.text.content(), "ac");
        assert_eq!(state.cursor, 1);
    }

    #[test]
    fn test_deplacer_gauche_droite() {
        let mut state = state_from("abc");
        state.go_to_start();
        state.move_right();
        assert_eq!(state.cursor, 1);
        state.move_left();
        assert_eq!(state.cursor, 0);
        state.move_left(); // borne gauche
        assert_eq!(state.cursor, 0);
    }

    #[test]
    fn test_aller_a_la_fin() {
        let mut state = state_from("hello");
        state.go_to_start();
        state.go_to_end();
        assert_eq!(state.cursor, 5);
    }

    #[test]
    fn test_toggler_style_sur_selection() {
        let mut state = state_from("hello");
        state.select(1..4);
        state.toggle_style(InlineStyle::Bold);
        let retour: Vec<InlineText> = Vec::from(&state.text);
        assert_eq!(retour[1].styles, vec![InlineStyle::Bold]);
        assert_eq!(retour[1].content, "ell");
    }

    #[test]
    fn test_inserer_efface_selection() {
        let mut state = state_from("abc");
        state.select(0..2);
        state.insert('X');
        assert!(state.selection.is_none());
    }
}
