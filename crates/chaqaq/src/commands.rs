use crate::{EditorState, InlineStyle, Span};
use std::ops::Range;

/// Interface du pattern Command : chaque opération d'édition est réversible.
pub trait Command {
    fn execute(&self, state: &mut EditorState);
    fn undo(&self, state: &mut EditorState);
}

// ── Commandes concrètes ──────────────────────────────────────────────────────

/// Insère un caractère à une position donnée.
pub struct Insert {
    pos: usize,
    ch: char,
}

impl Insert {
    pub fn new(pos: usize, ch: char) -> Self {
        Self { pos, ch }
    }
}

impl Command for Insert {
    fn execute(&self, state: &mut EditorState) {
        state.text.insert_char(self.pos, self.ch);
        state.cursor = self.pos + 1;
    }
    fn undo(&self, state: &mut EditorState) {
        state.text.delete_char(self.pos);
        state.cursor = self.pos;
    }
}

/// Supprime le caractère à une position donnée.
/// Retourne `None` si la position est hors limites.
pub struct Delete {
    pos: usize,
    ch: char, // stocké à la création pour pouvoir réinsérer lors de l'undo
}

impl Delete {
    pub fn new(state: &EditorState, pos: usize) -> Option<Self> {
        let ch = state.text.content().chars().nth(pos)?;
        Some(Self { pos, ch })
    }
}

impl Command for Delete {
    fn execute(&self, state: &mut EditorState) {
        state.text.delete_char(self.pos);
        state.cursor = self.pos;
    }
    fn undo(&self, state: &mut EditorState) {
        state.text.insert_char(self.pos, self.ch);
        state.cursor = self.pos + 1;
    }
}

/// Bascule un style sur une plage. Capture un snapshot des spans avant
/// l'exécution pour un undo exact (pas de re-calcul).
pub struct ApplyStyle {
    range: Range<usize>,
    style: InlineStyle,
    before_spans: Vec<Span>,
}

impl ApplyStyle {
    pub fn new(state: &EditorState, range: Range<usize>, style: InlineStyle) -> Self {
        Self {
            before_spans: state.text.spans().to_vec(),
            range,
            style,
        }
    }
}

impl Command for ApplyStyle {
    fn execute(&self, state: &mut EditorState) {
        state.text.toggle_style(self.range.clone(), self.style.clone());
    }
    fn undo(&self, state: &mut EditorState) {
        state.text.restore_spans(self.before_spans.clone());
    }
}

// ── History ──────────────────────────────────────────────────────────────────

const DEFAULT_CAPACITY: usize = 1000;

/// Pile d'historique undo/redo avec capacité configurable.
/// Au-delà de la capacité, les entrées les plus anciennes sont silencieusement supprimées.
pub struct History {
    done: Vec<Box<dyn Command>>,
    undone: Vec<Box<dyn Command>>,
    capacity: usize,
}

impl Default for History {
    fn default() -> Self {
        Self::new(DEFAULT_CAPACITY)
    }
}

impl History {
    pub fn new(capacity: usize) -> Self {
        Self {
            done: Vec::new(),
            undone: Vec::new(),
            capacity,
        }
    }

    /// Exécute la commande et l'enregistre dans l'historique.
    /// Efface le redo stack.
    pub fn apply(&mut self, cmd: Box<dyn Command>, state: &mut EditorState) {
        cmd.execute(state);
        self.done.push(cmd);
        self.undone.clear();
        if self.done.len() > self.capacity {
            self.done.remove(0);
        }
    }

    pub fn undo(&mut self, state: &mut EditorState) {
        if let Some(cmd) = self.done.pop() {
            cmd.undo(state);
            self.undone.push(cmd);
        }
    }

    pub fn redo(&mut self, state: &mut EditorState) {
        if let Some(cmd) = self.undone.pop() {
            cmd.execute(state);
            self.done.push(cmd);
        }
    }

    pub fn can_undo(&self) -> bool {
        !self.done.is_empty()
    }
    pub fn can_redo(&self) -> bool {
        !self.undone.is_empty()
    }
    pub fn capacity(&self) -> usize {
        self.capacity
    }
    pub fn size(&self) -> usize {
        self.done.len()
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
    fn test_inserer_puis_annuler() {
        let mut state = state_from("ac");
        let mut hist = History::default();
        state.cursor = 1;

        hist.apply(Box::new(Insert::new(1, 'b')), &mut state);
        assert_eq!(state.text.content(), "abc");
        assert_eq!(state.cursor, 2);

        hist.undo(&mut state);
        assert_eq!(state.text.content(), "ac");
        assert_eq!(state.cursor, 1);
    }

    #[test]
    fn test_supprimer_puis_annuler() {
        let mut state = state_from("abc");
        let mut hist = History::default();

        let cmd = Delete::new(&state, 1).unwrap();
        hist.apply(Box::new(cmd), &mut state);
        assert_eq!(state.text.content(), "ac");

        hist.undo(&mut state);
        assert_eq!(state.text.content(), "abc");
        assert_eq!(state.cursor, 2);
    }

    #[test]
    fn test_style_puis_annuler() {
        let mut state = state_from("hello");
        let mut hist = History::default();

        let cmd = ApplyStyle::new(&state, 1..4, InlineStyle::Bold);
        hist.apply(Box::new(cmd), &mut state);
        let retour: Vec<InlineText> = Vec::from(&state.text);
        assert_eq!(retour[1].styles, vec![InlineStyle::Bold]);

        hist.undo(&mut state);
        let retour: Vec<InlineText> = Vec::from(&state.text);
        assert!(retour[0].styles.is_empty());
    }

    #[test]
    fn test_undo_redo() {
        let mut state = state_from("");
        let mut hist = History::default();

        hist.apply(Box::new(Insert::new(0, 'a')), &mut state);
        hist.apply(Box::new(Insert::new(1, 'b')), &mut state);
        assert_eq!(state.text.content(), "ab");

        hist.undo(&mut state);
        assert_eq!(state.text.content(), "a");
        assert!(hist.can_redo());

        hist.redo(&mut state);
        assert_eq!(state.text.content(), "ab");
        assert!(!hist.can_redo());
    }

    #[test]
    fn test_new_action_efface_redo() {
        let mut state = state_from("");
        let mut hist = History::default();

        hist.apply(Box::new(Insert::new(0, 'a')), &mut state);
        hist.apply(Box::new(Insert::new(1, 'b')), &mut state);
        hist.undo(&mut state);

        hist.apply(Box::new(Insert::new(1, 'c')), &mut state);
        assert!(!hist.can_redo());
        assert_eq!(state.text.content(), "ac");
    }

    #[test]
    fn test_limite_undo_respectee() {
        let mut state = state_from("");
        let mut hist = History::new(3);

        for (i, ch) in ['a', 'b', 'c', 'd', 'e'].iter().enumerate() {
            hist.apply(Box::new(Insert::new(i, *ch)), &mut state);
        }
        assert_eq!(hist.size(), 3);
        assert_eq!(hist.capacity(), 3);
    }

    #[test]
    fn test_undo_apres_limite() {
        let mut state = state_from("");
        let mut hist = History::new(3);

        for (i, ch) in ['a', 'b', 'c', 'd', 'e'].iter().enumerate() {
            hist.apply(Box::new(Insert::new(i, *ch)), &mut state);
        }
        assert_eq!(state.text.content(), "abcde");

        hist.undo(&mut state);
        hist.undo(&mut state);
        hist.undo(&mut state);
        assert!(!hist.can_undo());
        assert_eq!(state.text.content(), "ab");
    }
}
