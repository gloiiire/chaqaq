#![allow(dead_code)]
use std::ops::Range;
use crate::domain::document::InlineStyle;
use crate::domain::rich_text::RichText;

pub struct EditorState {
    pub texte: RichText,
    pub curseur: usize,
    pub selection: Option<Range<usize>>,
}

impl EditorState {
    pub fn nouveau(texte: RichText) -> Self {
        let curseur = texte.longueur();
        Self { texte, curseur, selection: None }
    }

    pub fn inserer(&mut self, ch: char) {
        self.texte.inserer_char(self.curseur, ch);
        self.curseur += 1;
        self.selection = None;
    }

    /// Supprime le char avant le curseur (Backspace).
    pub fn supprimer_avant(&mut self) {
        if self.curseur == 0 { return; }
        self.curseur -= 1;
        self.texte.supprimer_char(self.curseur);
        self.selection = None;
    }

    /// Supprime le char après le curseur (Delete).
    pub fn supprimer_apres(&mut self) {
        self.texte.supprimer_char(self.curseur);
        self.selection = None;
    }

    pub fn deplacer_gauche(&mut self) {
        if self.curseur > 0 { self.curseur -= 1; }
        self.selection = None;
    }

    pub fn deplacer_droite(&mut self) {
        if self.curseur < self.texte.longueur() { self.curseur += 1; }
        self.selection = None;
    }

    pub fn aller_au_debut(&mut self) {
        self.curseur = 0;
        self.selection = None;
    }

    pub fn aller_a_la_fin(&mut self) {
        self.curseur = self.texte.longueur();
        self.selection = None;
    }

    pub fn selectionner(&mut self, range: Range<usize>) {
        self.selection = Some(range);
    }

    /// Bascule le style sur la sélection courante.
    pub fn toggler_style(&mut self, style: InlineStyle) {
        if let Some(range) = self.selection.clone() {
            self.texte.toggler_style(range, style);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::document::InlineStyle;
    use crate::domain::rich_text::RichText;
    use crate::domain::document::InlineText;

    fn etat_depuis(s: &str) -> EditorState {
        let inlines = vec![InlineText { content: s.to_string(), styles: vec![] }];
        EditorState::nouveau(RichText::from(&inlines))
    }

    #[test]
    fn test_inserer_avance_curseur() {
        let mut etat = etat_depuis("ab");
        etat.curseur = 1;
        etat.inserer('X');
        assert_eq!(etat.texte.contenu(), "aXb");
        assert_eq!(etat.curseur, 2);
    }

    #[test]
    fn test_supprimer_avant_recule_curseur() {
        let mut etat = etat_depuis("abc");
        etat.curseur = 2;
        etat.supprimer_avant();
        assert_eq!(etat.texte.contenu(), "ac");
        assert_eq!(etat.curseur, 1);
    }

    #[test]
    fn test_supprimer_avant_en_debut_ne_fait_rien() {
        let mut etat = etat_depuis("abc");
        etat.curseur = 0;
        etat.supprimer_avant();
        assert_eq!(etat.texte.contenu(), "abc");
        assert_eq!(etat.curseur, 0);
    }

    #[test]
    fn test_supprimer_apres_ne_bouge_pas_curseur() {
        let mut etat = etat_depuis("abc");
        etat.curseur = 1;
        etat.supprimer_apres();
        assert_eq!(etat.texte.contenu(), "ac");
        assert_eq!(etat.curseur, 1);
    }

    #[test]
    fn test_deplacer_gauche_droite() {
        let mut etat = etat_depuis("abc");
        etat.aller_au_debut();
        etat.deplacer_droite();
        assert_eq!(etat.curseur, 1);
        etat.deplacer_gauche();
        assert_eq!(etat.curseur, 0);
        etat.deplacer_gauche(); // borne gauche
        assert_eq!(etat.curseur, 0);
    }

    #[test]
    fn test_aller_a_la_fin() {
        let mut etat = etat_depuis("hello");
        etat.aller_au_debut();
        etat.aller_a_la_fin();
        assert_eq!(etat.curseur, 5);
    }

    #[test]
    fn test_toggler_style_sur_selection() {
        let mut etat = etat_depuis("hello");
        etat.selectionner(1..4);
        etat.toggler_style(InlineStyle::Bold);
        let retour: Vec<InlineText> = Vec::from(&etat.texte);
        assert_eq!(retour[1].styles, vec![InlineStyle::Bold]);
        assert_eq!(retour[1].content, "ell");
    }

    #[test]
    fn test_inserer_efface_selection() {
        let mut etat = etat_depuis("abc");
        etat.selectionner(0..2);
        etat.inserer('X');
        assert!(etat.selection.is_none());
    }
}
