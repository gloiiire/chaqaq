use crate::{InlineStyle, InlineText};
use std::ops::Range;

/// A contiguous styled region within a [`RichText`].
///
/// `range` uses **char indices** (not byte offsets) so multi-byte Unicode
/// characters are always handled correctly.
#[derive(Debug, Clone, PartialEq)]
pub struct Span {
    /// Char-index range `start..end` covered by this span.
    pub range: Range<usize>,
    /// Styles applied to every character in `range`.
    pub styles: Vec<InlineStyle>,
}

/// In-memory rich text representation: a flat char buffer plus style [`Span`]s.
///
/// All indices are **char positions**, not byte offsets — safe for any Unicode input.
///
/// # Conversion
///
/// `RichText` implements `From<&Vec<InlineText>>` and `Vec<InlineText>` implements
/// `From<&RichText>`, so you can round-trip with the serializable form losslessly.
///
/// ```rust
/// use chaqaq::{RichText, InlineText, InlineStyle};
///
/// let inlines = vec![
///     InlineText { content: "hello ".to_string(), styles: vec![] },
///     InlineText { content: "world".to_string(), styles: vec![InlineStyle::Bold] },
/// ];
/// let rt = RichText::from(&inlines);
/// let back: Vec<InlineText> = Vec::from(&rt);
/// assert_eq!(back, inlines);
/// ```
#[derive(Debug, Clone)]
pub struct RichText {
    chars: Vec<char>,
    spans: Vec<Span>,
}

impl RichText {
    /// Creates an empty `RichText`.
    pub fn empty() -> Self {
        Self {
            chars: vec![],
            spans: vec![],
        }
    }

    /// Returns the plain text content (all chars joined, no style info).
    pub fn content(&self) -> String {
        self.chars.iter().collect()
    }

    /// Number of Unicode characters (not bytes).
    pub fn length(&self) -> usize {
        self.chars.len()
    }

    /// Active style spans.
    pub fn spans(&self) -> &[Span] {
        &self.spans
    }

    /// Inserts `ch` at char position `pos`, shifting all spans right.
    pub fn insert_char(&mut self, pos: usize, ch: char) {
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

    /// Removes the character at char position `pos`, adjusting spans.
    /// Does nothing if `pos` is out of bounds.
    pub fn delete_char(&mut self, pos: usize) {
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

    /// Toggles `style` over `range`: adds it if any character lacks it,
    /// removes it if every character already has it.
    pub fn toggle_style(&mut self, range: Range<usize>, style: InlineStyle) {
        if range.is_empty() {
            return;
        }
        if self.all_have_style(range.clone(), &style) {
            self.remove_style(range, &style);
        } else {
            self.add_style(range, style);
        }
    }

    /// Replaces the span list verbatim — used by [`commands::ApplyStyle`](crate::commands::ApplyStyle) for exact undo.
    pub fn restore_spans(&mut self, spans: Vec<Span>) {
        self.spans = spans;
    }

    fn all_have_style(&self, range: Range<usize>, style: &InlineStyle) -> bool {
        range.into_iter().all(|i| {
            self.spans
                .iter()
                .any(|s| s.range.contains(&i) && s.styles.contains(style))
        })
    }

    fn add_style(&mut self, range: Range<usize>, style: InlineStyle) {
        let mut by_char = self.styles_by_char();
        for i in range {
            if i < by_char.len() && !by_char[i].contains(&style) {
                by_char[i].push(style.clone());
            }
        }
        self.spans = Self::build_spans(by_char);
    }

    fn remove_style(&mut self, range: Range<usize>, style: &InlineStyle) {
        // Only called from `toggle_style` after `all_have_style(range)` returned
        // true, which means every index in `range` is in a span — and every
        // span maps to a real char. So `i < by_char.len()` always holds and
        // no bound check is needed.
        let mut by_char = self.styles_by_char();
        for i in range {
            by_char[i].retain(|s| s != style);
        }
        self.spans = Self::build_spans(by_char);
    }

    fn styles_by_char(&self) -> Vec<Vec<InlineStyle>> {
        let mut result = vec![vec![]; self.chars.len()];
        for span in &self.spans {
            for i in span.range.clone() {
                result[i].extend(span.styles.clone());
            }
        }
        result
    }

    fn build_spans(by_char: Vec<Vec<InlineStyle>>) -> Vec<Span> {
        let mut spans = Vec::new();
        let mut i = 0;
        while i < by_char.len() {
            if by_char[i].is_empty() {
                i += 1;
                continue;
            }
            let styles = by_char[i].clone();
            let start = i;
            while i < by_char.len() && by_char[i] == styles {
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

        let by_char = rt.styles_by_char();
        let mut result = Vec::new();
        let mut i = 0;

        while i < rt.chars.len() {
            let styles = by_char[i].clone();
            let mut content = String::new();
            while i < rt.chars.len() && by_char[i] == styles {
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
    use crate::{InlineStyle, InlineText};

    fn bold(content: &str) -> InlineText {
        InlineText {
            content: content.to_string(),
            styles: vec![InlineStyle::Bold],
        }
    }
    fn text(content: &str) -> InlineText {
        InlineText {
            content: content.to_string(),
            styles: vec![],
        }
    }

    #[test]
    fn test_conversion_depuis_inlines() {
        let inlines = vec![text("avant "), bold("gras"), text(" après")];
        let rt = RichText::from(&inlines);
        assert_eq!(rt.content(), "avant gras après");
        assert_eq!(rt.spans().len(), 1);
        assert_eq!(rt.spans()[0].range, 6..10);
        assert_eq!(rt.spans()[0].styles, vec![InlineStyle::Bold]);
    }

    #[test]
    fn test_conversion_vers_inlines() {
        let inlines = vec![text("avant "), bold("gras"), text(" après")];
        let rt = RichText::from(&inlines);
        let retour: Vec<InlineText> = Vec::from(&rt);
        assert_eq!(retour, inlines);
    }

    #[test]
    fn test_aller_retour_texte_simple() {
        let inlines = vec![text("bonjour")];
        let retour: Vec<InlineText> = Vec::from(&RichText::from(&inlines));
        assert_eq!(retour, inlines);
    }

    #[test]
    fn test_inserer_char_decale_spans() {
        let inlines = vec![text("avant "), bold("gras"), text(" après")];
        let mut rt = RichText::from(&inlines);
        rt.insert_char(0, 'X');
        assert_eq!(rt.content(), "Xavant gras après");
        assert_eq!(rt.spans()[0].range, 7..11);
    }

    #[test]
    fn test_inserer_char_dans_span() {
        let inlines = vec![text("avant "), bold("gras"), text(" après")];
        let mut rt = RichText::from(&inlines);
        rt.insert_char(8, 'X');
        assert_eq!(rt.content(), "avant grXas après");
        assert_eq!(rt.spans()[0].range, 6..11);
    }

    #[test]
    fn test_supprimer_char_ajuste_spans() {
        let inlines = vec![text("avant "), bold("gras"), text(" après")];
        let mut rt = RichText::from(&inlines);
        rt.delete_char(0);
        assert_eq!(rt.content(), "vant gras après");
        assert_eq!(rt.spans()[0].range, 5..9);
    }

    #[test]
    fn test_supprimer_char_supprime_span_vide() {
        let inlines = vec![text("a"), bold("b"), text("c")];
        let mut rt = RichText::from(&inlines);
        rt.delete_char(1);
        assert_eq!(rt.content(), "ac");
        assert!(rt.spans().is_empty());
    }

    #[test]
    fn test_toggler_style_ajoute() {
        let inlines = vec![text("hello")];
        let mut rt = RichText::from(&inlines);
        rt.toggle_style(1..3, InlineStyle::Bold);
        let retour: Vec<InlineText> = Vec::from(&rt);
        assert_eq!(retour, vec![text("h"), bold("el"), text("lo")]);
    }

    #[test]
    fn test_toggler_style_retire_si_tous_ont_le_style() {
        let inlines = vec![text("a"), bold("bcd"), text("e")];
        let mut rt = RichText::from(&inlines);
        rt.toggle_style(1..4, InlineStyle::Bold);
        let retour: Vec<InlineText> = Vec::from(&rt);
        assert_eq!(retour, vec![text("abcde")]);
    }

    #[test]
    fn test_unicode_accents() {
        let inlines = vec![text("éàü")];
        let mut rt = RichText::from(&inlines);
        assert_eq!(rt.length(), 3);
        rt.insert_char(1, 'X');
        assert_eq!(rt.content(), "éXàü");
    }

    #[test]
    fn empty_yields_no_chars_and_no_spans() {
        let rt = RichText::empty();
        assert_eq!(rt.length(), 0);
        assert_eq!(rt.content(), "");
        assert!(rt.spans().is_empty());
    }

    #[test]
    fn delete_char_past_end_is_noop() {
        let mut rt = RichText::from(&vec![text("abc")]);
        rt.delete_char(99);
        assert_eq!(rt.content(), "abc");
    }

    #[test]
    fn toggle_style_with_empty_range_is_noop() {
        let mut rt = RichText::from(&vec![text("hello")]);
        rt.toggle_style(2..2, InlineStyle::Bold);
        assert!(rt.spans().is_empty());
    }

    #[test]
    fn remove_style_clears_style_when_all_have_it() {
        // Style covers full range → toggle_style routes to remove_style,
        // which exercises the by_char[i].retain branch.
        let mut rt = RichText::from(&vec![bold("abc")]);
        rt.toggle_style(0..3, InlineStyle::Bold);
        let back: Vec<InlineText> = Vec::from(&rt);
        assert_eq!(back, vec![text("abc")]);
    }

    #[test]
    fn from_empty_rich_text_to_inline_vec_yields_empty() {
        let rt = RichText::empty();
        let back: Vec<InlineText> = Vec::from(&rt);
        assert!(back.is_empty());
    }
}
