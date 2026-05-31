use crate::{InlineStyle, RichText};
use std::ops::Range;

/// Editor state: rich text buffer, cursor position, and optional selection.
///
/// All indices are **char positions** (not byte offsets).
///
/// # Example
///
/// ```rust
/// use chaqaq::{EditorState, RichText, InlineStyle, InlineText};
///
/// let inlines = vec![InlineText { content: "hello".to_string(), styles: vec![] }];
/// let mut editor = EditorState::new(RichText::from(&inlines));
///
/// editor.go_to_start();
/// editor.insert('H');
/// assert_eq!(editor.text.content(), "Hhello");
///
/// editor.select(0..1);
/// editor.toggle_style(InlineStyle::Bold);
/// ```
pub struct EditorState {
    /// The rich text buffer.
    pub text: RichText,
    /// Current cursor position (char index).
    pub cursor: usize,
    /// Active selection range, if any.
    pub selection: Option<Range<usize>>,
}

impl EditorState {
    /// Creates a new `EditorState` with the cursor placed at the end of `text`.
    pub fn new(text: RichText) -> Self {
        let cursor = text.length();
        Self {
            text,
            cursor,
            selection: None,
        }
    }

    /// Inserts `ch` at the cursor position and advances the cursor by one.
    /// Clears the selection.
    pub fn insert(&mut self, ch: char) {
        self.text.insert_char(self.cursor, ch);
        self.cursor += 1;
        self.selection = None;
    }

    /// Removes the character before the cursor (Backspace).
    /// Does nothing when the cursor is at position 0.
    pub fn delete_before(&mut self) {
        if self.cursor == 0 {
            return;
        }
        self.cursor -= 1;
        self.text.delete_char(self.cursor);
        self.selection = None;
    }

    /// Removes the character after the cursor (Delete / Forward-delete).
    pub fn delete_after(&mut self) {
        self.text.delete_char(self.cursor);
        self.selection = None;
    }

    /// Moves the cursor one character to the left. Clamps at 0.
    pub fn move_left(&mut self) {
        if self.cursor > 0 {
            self.cursor -= 1;
        }
        self.selection = None;
    }

    /// Moves the cursor one character to the right. Clamps at `text.length()`.
    pub fn move_right(&mut self) {
        if self.cursor < self.text.length() {
            self.cursor += 1;
        }
        self.selection = None;
    }

    /// Moves the cursor to the beginning of the text.
    pub fn go_to_start(&mut self) {
        self.cursor = 0;
        self.selection = None;
    }

    /// Moves the cursor to the end of the text.
    pub fn go_to_end(&mut self) {
        self.cursor = self.text.length();
        self.selection = None;
    }

    /// Sets the active selection to `range`.
    pub fn select(&mut self, range: Range<usize>) {
        self.selection = Some(range);
    }

    /// Toggles `style` over the current selection.
    /// Does nothing if there is no active selection.
    pub fn toggle_style(&mut self, style: InlineStyle) {
        if let Some(range) = self.selection.clone() {
            self.text.toggle_style(range, style);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{InlineStyle, InlineText, RichText};

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
        state.move_left();
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
