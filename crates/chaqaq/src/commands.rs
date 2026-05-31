use crate::{EditorState, InlineStyle, Span};
use std::ops::Range;

/// A reversible editing operation on an [`EditorState`].
///
/// Implement this trait to add custom undo-able commands.
/// Built-in implementations: [`Insert`], [`Delete`], [`ApplyStyle`].
pub trait Command {
    /// Applies the command to `state`.
    fn execute(&self, state: &mut EditorState);
    /// Reverses the effect of [`execute`](Command::execute).
    fn undo(&self, state: &mut EditorState);
}

// ── Concrete commands ────────────────────────────────────────────────────────

/// Inserts a single character at a given position.
pub struct Insert {
    pos: usize,
    ch: char,
}

impl Insert {
    /// Creates an `Insert` command that will place `ch` at char position `pos`.
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

/// Deletes the character at a given position.
///
/// Returns `None` if `pos` is out of bounds.
pub struct Delete {
    pos: usize,
    ch: char,
}

impl Delete {
    /// Captures the character at `pos` from `state` so it can be reinserted on undo.
    /// Returns `None` if `pos` is out of bounds.
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

/// Toggles an [`InlineStyle`] over a char range.
///
/// Captures a snapshot of all spans before execution so that `undo` can
/// restore the exact previous state without recomputation.
pub struct ApplyStyle {
    range: Range<usize>,
    style: InlineStyle,
    before_spans: Vec<Span>,
}

impl ApplyStyle {
    /// Creates an `ApplyStyle` command. Captures the current span state from `state`.
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

/// Undo/redo stack with a configurable capacity.
///
/// Once the capacity is reached, the oldest entries are silently dropped.
///
/// # Example
///
/// ```rust
/// use chaqaq::{EditorState, RichText, InlineText};
/// use chaqaq::commands::{History, Insert};
///
/// let inlines = vec![InlineText { content: "ac".to_string(), styles: vec![] }];
/// let mut editor = EditorState::new(RichText::from(&inlines));
/// let mut hist = History::default();
///
/// editor.cursor = 1;
/// hist.apply(Box::new(Insert::new(1, 'b')), &mut editor);
/// assert_eq!(editor.text.content(), "abc");
///
/// hist.undo(&mut editor);
/// assert_eq!(editor.text.content(), "ac");
///
/// hist.redo(&mut editor);
/// assert_eq!(editor.text.content(), "abc");
/// ```
pub struct History {
    done: Vec<Box<dyn Command>>,
    undone: Vec<Box<dyn Command>>,
    capacity: usize,
}

impl Default for History {
    /// Creates a `History` with the default capacity of 1 000 levels.
    fn default() -> Self {
        Self::new(DEFAULT_CAPACITY)
    }
}

impl History {
    /// Creates a `History` with a custom `capacity`.
    pub fn new(capacity: usize) -> Self {
        Self {
            done: Vec::new(),
            undone: Vec::new(),
            capacity,
        }
    }

    /// Executes `cmd` and pushes it onto the undo stack.
    /// Clears the redo stack — a new action always discards future redo entries.
    pub fn apply(&mut self, cmd: Box<dyn Command>, state: &mut EditorState) {
        cmd.execute(state);
        self.done.push(cmd);
        self.undone.clear();
        if self.done.len() > self.capacity {
            self.done.remove(0);
        }
    }

    /// Undoes the most recent command and pushes it onto the redo stack.
    /// Does nothing if the undo stack is empty.
    pub fn undo(&mut self, state: &mut EditorState) {
        if let Some(cmd) = self.done.pop() {
            cmd.undo(state);
            self.undone.push(cmd);
        }
    }

    /// Re-applies the most recently undone command.
    /// Does nothing if the redo stack is empty.
    pub fn redo(&mut self, state: &mut EditorState) {
        if let Some(cmd) = self.undone.pop() {
            cmd.execute(state);
            self.done.push(cmd);
        }
    }

    /// Returns `true` if there is at least one command that can be undone.
    pub fn can_undo(&self) -> bool {
        !self.done.is_empty()
    }

    /// Returns `true` if there is at least one command that can be redone.
    pub fn can_redo(&self) -> bool {
        !self.undone.is_empty()
    }

    /// The configured maximum number of undo levels.
    pub fn capacity(&self) -> usize {
        self.capacity
    }

    /// Current number of commands in the undo stack.
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
