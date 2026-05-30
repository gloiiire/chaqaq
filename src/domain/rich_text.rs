#![allow(dead_code)]
use crate::domain::document::{InlineStyle, InlineText};
use std::ops::Range;

/// Plage de texte stylisée. Les indices sont des positions de chars Unicode,
/// pas des offsets bytes — évite les bugs avec les caractères multi-octets.
#[derive(Debug, Clone, PartialEq)]
pub struct Span {
    pub range: Range<usize>,
    pub styles: Vec<InlineStyle>,
}

/// Représentation d'édition du texte riche : string plate + annotations de style.
/// Conversion depuis/vers Vec<InlineText> pour la persistance.
#[derive(Debug, Clone)]
pub struct RichText {
    chars: Vec<char>,
    spans: Vec<Span>,
}

impl RichText {
    pub fn vide() -> Self {
        Self {
            chars: vec![],
            spans: vec![],
        }
    }

    pub fn content(&self) -> String {
        self.chars.iter().collect()
    }

    pub fn longueur(&self) -> usize {
        self.chars.len()
    }

    pub fn spans(&self) -> &[Span] {
        &self.spans
    }

    pub fn inserer_char(&mut self, pos: usize, ch: char) {
        self.chars.insert(pos, ch);
        for span in &mut self.spans {
            if span.range.start >= pos {
                span.range.start += 1;
                span.range.end += 1;
            } else if span.range.end > pos {
                span.range.end += 1;
            }
        }
    }

    pub fn supprimer_char(&mut self, pos: usize) {
        if pos >= self.chars.len() {
            return;
        }
        self.chars.remove(pos);
        self.spans.retain_mut(|span| {
            if span.range.start > pos {
                span.range.start -= 1;
                span.range.end -= 1;
            } else if span.range.end > pos {
                span.range.end -= 1;
            }
            !span.range.is_empty()
        });
    }

    /// Bascule le style sur la plage : ajoute si au moins un char ne l'a pas,
    /// retire si tous l'ont déjà.
    pub fn toggler_style(&mut self, range: Range<usize>, style: InlineStyle) {
        if range.is_empty() {
            return;
        }
        if self.tous_ont_style(range.clone(), &style) {
            self.retirer_style(range, &style);
        } else {
            self.ajouter_style(range, style);
        }
    }

    pub fn restaurer_spans(&mut self, spans: Vec<Span>) {
        self.spans = spans;
    }

    fn tous_ont_style(&self, range: Range<usize>, style: &InlineStyle) -> bool {
        range.into_iter().all(|i| {
            self.spans
                .iter()
                .any(|s| s.range.contains(&i) && s.styles.contains(style))
        })
    }

    fn ajouter_style(&mut self, range: Range<usize>, style: InlineStyle) {
        let mut par_char = self.styles_par_char();
        for i in range {
            if i < par_char.len() && !par_char[i].contains(&style) {
                par_char[i].push(style.clone());
            }
        }
        self.spans = Self::construire_spans(par_char);
    }

    fn retirer_style(&mut self, range: Range<usize>, style: &InlineStyle) {
        let mut par_char = self.styles_par_char();
        for i in range {
            if i < par_char.len() {
                par_char[i].retain(|s| s != style);
            }
        }
        self.spans = Self::construire_spans(par_char);
    }

    fn styles_par_char(&self) -> Vec<Vec<InlineStyle>> {
        let mut result = vec![vec![]; self.chars.len()];
        for span in &self.spans {
            for i in span.range.clone() {
                result[i].extend(span.styles.clone());
            }
        }
        result
    }

    fn construire_spans(par_char: Vec<Vec<InlineStyle>>) -> Vec<Span> {
        let mut spans = Vec::new();
        let mut i = 0;
        while i < par_char.len() {
            if par_char[i].is_empty() {
                i += 1;
                continue;
            }
            let styles = par_char[i].clone();
            let start = i;
            while i < par_char.len() && par_char[i] == styles {
                i += 1;
            }
            spans.push(Span {
                range: start..i,
                styles,
            });
        }
        spans
    }
}

impl From<&Vec<InlineText>> for RichText {
    fn from(inlines: &Vec<InlineText>) -> Self {
        let mut chars = Vec::new();
        let mut spans = Vec::new();
        let mut pos = 0;

        for inline in inlines {
            let start = pos;
            let inline_chars: Vec<char> = inline.content.chars().collect();
            pos += inline_chars.len();
            chars.extend(inline_chars);

            if !inline.styles.is_empty() {
                spans.push(Span {
                    range: start..pos,
                    styles: inline.styles.clone(),
                });
            }
        }

        RichText { chars, spans }
    }
}

impl From<&RichText> for Vec<InlineText> {
    fn from(rt: &RichText) -> Self {
        if rt.chars.is_empty() {
            return vec![];
        }

        let par_char = rt.styles_par_char();
        let mut result = Vec::new();
        let mut i = 0;

        while i < rt.chars.len() {
            let styles = par_char[i].clone();
            let mut content = String::new();
            while i < rt.chars.len() && par_char[i] == styles {
                content.push(rt.chars[i]);
                i += 1;
            }
            result.push(InlineText { content, styles });
        }

        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::document::{InlineStyle, InlineText};

    fn gras(content: &str) -> InlineText {
        InlineText {
            content: content.to_string(),
            styles: vec![InlineStyle::Bold],
        }
    }
    fn texte(content: &str) -> InlineText {
        InlineText {
            content: content.to_string(),
            styles: vec![],
        }
    }

    #[test]
    fn test_conversion_depuis_inlines() {
        let inlines = vec![texte("avant "), gras("gras"), texte(" après")];
        let rt = RichText::from(&inlines);
        assert_eq!(rt.content(), "avant gras après");
        assert_eq!(rt.spans().len(), 1);
        assert_eq!(rt.spans()[0].range, 6..10);
        assert_eq!(rt.spans()[0].styles, vec![InlineStyle::Bold]);
    }

    #[test]
    fn test_conversion_vers_inlines() {
        let inlines = vec![texte("avant "), gras("gras"), texte(" après")];
        let rt = RichText::from(&inlines);
        let retour: Vec<InlineText> = Vec::from(&rt);
        assert_eq!(retour, inlines);
    }

    #[test]
    fn test_aller_retour_texte_simple() {
        let inlines = vec![texte("bonjour")];
        let retour: Vec<InlineText> = Vec::from(&RichText::from(&inlines));
        assert_eq!(retour, inlines);
    }

    #[test]
    fn test_inserer_char_decale_spans() {
        let inlines = vec![texte("avant "), gras("gras"), texte(" après")];
        let mut rt = RichText::from(&inlines);
        // insertion à la position 0
        rt.inserer_char(0, 'X');
        assert_eq!(rt.content(), "Xavant gras après");
        assert_eq!(rt.spans()[0].range, 7..11); // décalé de 1
    }

    #[test]
    fn test_inserer_char_dans_span() {
        let inlines = vec![texte("avant "), gras("gras"), texte(" après")];
        let mut rt = RichText::from(&inlines);
        // insertion au milieu du span "gras" (pos 8 = entre 'r' et 'a' de "gras")
        rt.inserer_char(8, 'X');
        assert_eq!(rt.content(), "avant grXas après");
        assert_eq!(rt.spans()[0].range, 6..11); // étendu de 1
    }

    #[test]
    fn test_supprimer_char_ajuste_spans() {
        let inlines = vec![texte("avant "), gras("gras"), texte(" après")];
        let mut rt = RichText::from(&inlines);
        rt.supprimer_char(0); // supprime 'a' de "avant"
        assert_eq!(rt.content(), "vant gras après");
        assert_eq!(rt.spans()[0].range, 5..9);
    }

    #[test]
    fn test_supprimer_char_supprime_span_vide() {
        let inlines = vec![texte("a"), gras("b"), texte("c")];
        let mut rt = RichText::from(&inlines);
        rt.supprimer_char(1); // supprime le 'b' en gras
        assert_eq!(rt.content(), "ac");
        assert!(rt.spans().is_empty());
    }

    #[test]
    fn test_toggler_style_ajoute() {
        let inlines = vec![texte("hello")];
        let mut rt = RichText::from(&inlines);
        rt.toggler_style(1..3, InlineStyle::Bold);
        let retour: Vec<InlineText> = Vec::from(&rt);
        assert_eq!(retour, vec![texte("h"), gras("el"), texte("lo")]);
    }

    #[test]
    fn test_toggler_style_retire_si_tous_ont_le_style() {
        let inlines = vec![texte("a"), gras("bcd"), texte("e")];
        let mut rt = RichText::from(&inlines);
        rt.toggler_style(1..4, InlineStyle::Bold); // tous ont Bold → retire
        let retour: Vec<InlineText> = Vec::from(&rt);
        assert_eq!(retour, vec![texte("abcde")]);
    }

    #[test]
    fn test_unicode_accents() {
        let inlines = vec![texte("éàü")];
        let mut rt = RichText::from(&inlines);
        assert_eq!(rt.longueur(), 3); // 3 chars, pas 6 bytes
        rt.inserer_char(1, 'X');
        assert_eq!(rt.content(), "éXàü");
    }
}
