#![allow(dead_code)]
use std::ops::Range;
use crate::domain::document::InlineStyle;
use crate::domain::editor::EditorState;
use crate::domain::rich_text::Span;

pub trait Commande {
    fn executer(&self, etat: &mut EditorState);
    fn annuler(&self, etat: &mut EditorState);
}

// ── Commandes concrètes ──────────────────────────────────────────────────────

pub struct Inserer {
    pos: usize,
    ch: char,
}

impl Inserer {
    pub fn nouveau(pos: usize, ch: char) -> Self {
        Self { pos, ch }
    }
}

impl Commande for Inserer {
    fn executer(&self, etat: &mut EditorState) {
        etat.texte.inserer_char(self.pos, self.ch);
        etat.curseur = self.pos + 1;
    }
    fn annuler(&self, etat: &mut EditorState) {
        etat.texte.supprimer_char(self.pos);
        etat.curseur = self.pos;
    }
}

pub struct Supprimer {
    pos: usize,
    ch: char, // stocké à la création pour pouvoir réinsérer lors de l'undo
}

impl Supprimer {
    pub fn nouveau(etat: &EditorState, pos: usize) -> Option<Self> {
        let ch = etat.texte.contenu().chars().nth(pos)?;
        Some(Self { pos, ch })
    }
}

impl Commande for Supprimer {
    fn executer(&self, etat: &mut EditorState) {
        etat.texte.supprimer_char(self.pos);
        etat.curseur = self.pos;
    }
    fn annuler(&self, etat: &mut EditorState) {
        etat.texte.inserer_char(self.pos, self.ch);
        etat.curseur = self.pos + 1;
    }
}

pub struct AppliquerStyle {
    range: Range<usize>,
    style: InlineStyle,
    avant_spans: Vec<Span>, // snapshot pour l'undo exact
}

impl AppliquerStyle {
    pub fn nouveau(etat: &EditorState, range: Range<usize>, style: InlineStyle) -> Self {
        Self {
            avant_spans: etat.texte.spans().to_vec(),
            range,
            style,
        }
    }
}

impl Commande for AppliquerStyle {
    fn executer(&self, etat: &mut EditorState) {
        etat.texte.toggler_style(self.range.clone(), self.style.clone());
    }
    fn annuler(&self, etat: &mut EditorState) {
        etat.texte.restaurer_spans(self.avant_spans.clone());
    }
}

// ── Historique ───────────────────────────────────────────────────────────────

#[derive(Default)]
pub struct Historique {
    fait: Vec<Box<dyn Commande>>,
    annule: Vec<Box<dyn Commande>>,
}

impl Historique {
    pub fn appliquer(&mut self, cmd: Box<dyn Commande>, etat: &mut EditorState) {
        cmd.executer(etat);
        self.fait.push(cmd);
        self.annule.clear(); // une nouvelle action efface le redo
    }

    pub fn annuler(&mut self, etat: &mut EditorState) {
        if let Some(cmd) = self.fait.pop() {
            cmd.annuler(etat);
            self.annule.push(cmd);
        }
    }

    pub fn refaire(&mut self, etat: &mut EditorState) {
        if let Some(cmd) = self.annule.pop() {
            cmd.executer(etat);
            self.fait.push(cmd);
        }
    }

    pub fn peut_annuler(&self) -> bool { !self.fait.is_empty() }
    pub fn peut_refaire(&self) -> bool { !self.annule.is_empty() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::document::{InlineStyle, InlineText};
    use crate::domain::rich_text::RichText;

    fn etat_depuis(s: &str) -> EditorState {
        let inlines = vec![InlineText { content: s.to_string(), styles: vec![] }];
        EditorState::nouveau(RichText::from(&inlines))
    }

    #[test]
    fn test_inserer_puis_annuler() {
        let mut etat = etat_depuis("ac");
        let mut hist = Historique::default();
        etat.curseur = 1;

        hist.appliquer(Box::new(Inserer::nouveau(1, 'b')), &mut etat);
        assert_eq!(etat.texte.contenu(), "abc");
        assert_eq!(etat.curseur, 2);

        hist.annuler(&mut etat);
        assert_eq!(etat.texte.contenu(), "ac");
        assert_eq!(etat.curseur, 1);
    }

    #[test]
    fn test_supprimer_puis_annuler() {
        let mut etat = etat_depuis("abc");
        let mut hist = Historique::default();

        let cmd = Supprimer::nouveau(&etat, 1).unwrap();
        hist.appliquer(Box::new(cmd), &mut etat);
        assert_eq!(etat.texte.contenu(), "ac");

        hist.annuler(&mut etat);
        assert_eq!(etat.texte.contenu(), "abc");
        assert_eq!(etat.curseur, 2);
    }

    #[test]
    fn test_style_puis_annuler() {
        let mut etat = etat_depuis("hello");
        let mut hist = Historique::default();

        let cmd = AppliquerStyle::nouveau(&etat, 1..4, InlineStyle::Bold);
        hist.appliquer(Box::new(cmd), &mut etat);
        let retour: Vec<InlineText> = Vec::from(&etat.texte);
        assert_eq!(retour[1].styles, vec![InlineStyle::Bold]);

        hist.annuler(&mut etat);
        let retour: Vec<InlineText> = Vec::from(&etat.texte);
        assert!(retour[0].styles.is_empty()); // retour à l'état initial
    }

    #[test]
    fn test_undo_redo() {
        let mut etat = etat_depuis("");
        let mut hist = Historique::default();

        hist.appliquer(Box::new(Inserer::nouveau(0, 'a')), &mut etat);
        hist.appliquer(Box::new(Inserer::nouveau(1, 'b')), &mut etat);
        assert_eq!(etat.texte.contenu(), "ab");

        hist.annuler(&mut etat);
        assert_eq!(etat.texte.contenu(), "a");
        assert!(hist.peut_refaire());

        hist.refaire(&mut etat);
        assert_eq!(etat.texte.contenu(), "ab");
        assert!(!hist.peut_refaire());
    }

    #[test]
    fn test_nouvelle_action_efface_redo() {
        let mut etat = etat_depuis("");
        let mut hist = Historique::default();

        hist.appliquer(Box::new(Inserer::nouveau(0, 'a')), &mut etat);
        hist.appliquer(Box::new(Inserer::nouveau(1, 'b')), &mut etat);
        hist.annuler(&mut etat); // peut refaire 'b'

        hist.appliquer(Box::new(Inserer::nouveau(1, 'c')), &mut etat); // nouvelle action
        assert!(!hist.peut_refaire()); // redo effacé
        assert_eq!(etat.texte.contenu(), "ac");
    }
}
