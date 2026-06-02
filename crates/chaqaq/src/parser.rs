use crate::{InlineStyle, InlineText};

enum LinkState {
    Text(String),
    WaitingUrl(String),
    Url(String, String),
}

enum ColorState {
    ColorName(String),
    Text(String, String), // (couleur, texte)
}

fn flush(result: &mut Vec<InlineText>, current_text: &mut String, styles: Vec<InlineStyle>) {
    if !current_text.is_empty() {
        result.push(InlineText {
            content: current_text.clone(),
            styles,
        });
        current_text.clear();
    }
}

fn active_styles(bold: bool, italic: bool, underline: bool, strikethrough: bool) -> Vec<InlineStyle> {
    let mut styles = vec![];
    if bold {
        styles.push(InlineStyle::Bold);
    }
    if italic {
        styles.push(InlineStyle::Italic);
    }
    if underline {
        styles.push(InlineStyle::Underline);
    }
    if strikethrough {
        styles.push(InlineStyle::Strikethrough);
    }
    styles
}

/// Parse une chaîne avec les raccourcis inline et retourne des `InlineText`.
///
/// Syntaxe supportée :
/// - `**gras**` → Bold
/// - `_italique_` → Italic
/// - `__souligné__` → Underline
/// - `~~barré~~` → Strikethrough
/// - `{couleur:texte}` → Color("couleur")
/// - `[texte](url)` → Link(url)
/// - Combinaisons : `**_gras+italique_**`
pub fn parse_inline(input: &str) -> Vec<InlineText> {
    let mut block: Vec<InlineText> = vec![];
    let mut current_text = String::new();
    let mut chars = input.chars().peekable();
    let mut bold = false;
    let mut italic = false;
    let mut underline = false;
    let mut strikethrough = false;
    let mut link: Option<LinkState> = None;
    let mut color: Option<ColorState> = None;

    while let Some(ch) = chars.next() {
        match ch {
            '*' if chars.peek() == Some(&'*') && link.is_none() && color.is_none() => {
                chars.next();
                flush(&mut block, &mut current_text, active_styles(bold, italic, underline, strikethrough));
                bold = !bold;
            }
            '*' if link.is_none() && color.is_none() => current_text.push('*'),

            '~' if chars.peek() == Some(&'~') && link.is_none() && color.is_none() => {
                chars.next();
                flush(&mut block, &mut current_text, active_styles(bold, italic, underline, strikethrough));
                strikethrough = !strikethrough;
            }
            '~' if link.is_none() && color.is_none() => current_text.push('~'),

            '_' if chars.peek() == Some(&'_') && link.is_none() && color.is_none() => {
                chars.next();
                flush(&mut block, &mut current_text, active_styles(bold, italic, underline, strikethrough));
                underline = !underline;
            }
            '_' if link.is_none() && color.is_none() => {
                flush(&mut block, &mut current_text, active_styles(bold, italic, underline, strikethrough));
                italic = !italic;
            }

            '{' if link.is_none() && color.is_none() => {
                flush(&mut block, &mut current_text, active_styles(bold, italic, underline, strikethrough));
                color = Some(ColorState::ColorName(String::new()));
            }
            ':' if matches!(color, Some(ColorState::ColorName(_))) => {
                if let Some(ColorState::ColorName(name)) = color.take() {
                    color = Some(ColorState::Text(name, String::new()));
                }
            }
            '}' if color.is_some() => {
                // The `color.is_some()` guard ensures the unwrap is safe.
                let state = color.take().unwrap();
                match state {
                    ColorState::Text(color_name, mut text) => {
                        flush(&mut block, &mut text, vec![InlineStyle::Color(color_name)]);
                    }
                    ColorState::ColorName(name) => {
                        current_text.push('{');
                        current_text.push_str(&name);
                        current_text.push('}');
                    }
                }
            }

            '[' if link.is_none() && color.is_none() => {
                flush(&mut block, &mut current_text, active_styles(bold, italic, underline, strikethrough));
                link = Some(LinkState::Text(String::new()));
            }
            ']' if matches!(link, Some(LinkState::Text(_))) => {
                if let Some(LinkState::Text(content)) = link.take() {
                    link = Some(LinkState::WaitingUrl(content));
                }
            }
            '(' if matches!(link, Some(LinkState::WaitingUrl(_))) => {
                if let Some(LinkState::WaitingUrl(content)) = link.take() {
                    link = Some(LinkState::Url(content, String::new()));
                }
            }
            ')' if matches!(link, Some(LinkState::Url(_, _))) => {
                if let Some(LinkState::Url(mut content, url)) = link.take() {
                    flush(&mut block, &mut content, vec![InlineStyle::Link(url)]);
                }
            }

            _ => {
                if let Some(LinkState::Text(ref mut content)) = link {
                    content.push(ch);
                } else if let Some(LinkState::Url(_, ref mut url)) = link {
                    url.push(ch);
                } else if let Some(ColorState::ColorName(ref mut name)) = color {
                    name.push(ch);
                } else if let Some(ColorState::Text(_, ref mut text)) = color {
                    text.push(ch);
                } else {
                    current_text.push(ch);
                }
            }
        }
    }

    if !current_text.is_empty() {
        block.push(InlineText {
            content: current_text,
            styles: active_styles(bold, italic, underline, strikethrough),
        });
    }

    block
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{InlineStyle, InlineText};

    fn text(content: &str) -> InlineText {
        InlineText { content: content.to_string(), styles: vec![] }
    }
    fn bold(content: &str) -> InlineText {
        InlineText { content: content.to_string(), styles: vec![InlineStyle::Bold] }
    }
    fn italic(content: &str) -> InlineText {
        InlineText { content: content.to_string(), styles: vec![InlineStyle::Italic] }
    }
    fn underlined(content: &str) -> InlineText {
        InlineText { content: content.to_string(), styles: vec![InlineStyle::Underline] }
    }
    fn strikethrough(content: &str) -> InlineText {
        InlineText { content: content.to_string(), styles: vec![InlineStyle::Strikethrough] }
    }
    fn bold_italic(content: &str) -> InlineText {
        InlineText { content: content.to_string(), styles: vec![InlineStyle::Bold, InlineStyle::Italic] }
    }
    fn link(content: &str, url: &str) -> InlineText {
        InlineText { content: content.to_string(), styles: vec![InlineStyle::Link(url.to_string())] }
    }
    fn color(content: &str, c: &str) -> InlineText {
        InlineText { content: content.to_string(), styles: vec![InlineStyle::Color(c.to_string())] }
    }

    #[test]
    fn test_texte_simple() {
        assert_eq!(parse_inline("bonjour"), vec![text("bonjour")]);
    }

    #[test]
    fn test_gras() {
        assert_eq!(
            parse_inline("avant **gras** après"),
            vec![text("avant "), bold("gras"), text(" après")]
        );
    }

    #[test]
    fn test_italique() {
        assert_eq!(
            parse_inline("avant _italique_ après"),
            vec![text("avant "), italic("italique"), text(" après")]
        );
    }

    #[test]
    fn test_souligne() {
        assert_eq!(
            parse_inline("avant __souligné__ après"),
            vec![text("avant "), underlined("souligné"), text(" après")]
        );
    }

    #[test]
    fn test_barre() {
        assert_eq!(
            parse_inline("avant ~~barré~~ après"),
            vec![text("avant "), strikethrough("barré"), text(" après")]
        );
    }

    #[test]
    fn test_couleur() {
        assert_eq!(
            parse_inline("{rouge:texte coloré}"),
            vec![color("texte coloré", "rouge")]
        );
    }

    #[test]
    fn test_couleur_avec_contexte() {
        assert_eq!(
            parse_inline("voir {bleu:ici} suite"),
            vec![text("voir "), color("ici", "bleu"), text(" suite")]
        );
    }

    #[test]
    fn test_accolade_sans_deux_points() {
        assert_eq!(parse_inline("{texte}"), vec![text("{texte}")]);
    }

    #[test]
    fn test_lien() {
        assert_eq!(
            parse_inline("[texte](https://example.com)"),
            vec![link("texte", "https://example.com")]
        );
    }

    #[test]
    fn test_lien_avec_contexte() {
        assert_eq!(
            parse_inline("voir [doc](https://doc.rs) ici"),
            vec![text("voir "), link("doc", "https://doc.rs"), text(" ici")]
        );
    }

    #[test]
    fn test_etoile_simple_litterale() {
        assert_eq!(parse_inline("a * b"), vec![text("a * b")]);
    }

    #[test]
    fn test_gras_italique() {
        assert_eq!(
            parse_inline("**_combiné_**"),
            vec![bold_italic("combiné")]
        );
    }

    #[test]
    fn single_tilde_is_literal_when_not_followed_by_another() {
        // Covers the `'~' if link.is_none() && color.is_none() =>
        // current_text.push('~')` branch — single ~ outside any context.
        assert_eq!(parse_inline("a ~ b"), vec![text("a ~ b")]);
    }

    #[test]
    fn unclosed_color_brace_falls_back_to_literal_braces() {
        // `{red:hello}` is parsed as color, but `{red}` (no `:`) closes
        // back to literal braces — exercises the ColorName fallback path.
        assert_eq!(parse_inline("{red}"), vec![text("{red}")]);
    }
}
