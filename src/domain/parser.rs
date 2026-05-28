#![allow(dead_code)]
use crate::domain::document::{InlineStyle, InlineText};

enum LinkState {
    Text(String),
    WaitingUrl(String),
    Url(String, String),
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

fn actifs(bold: bool, italic: bool) -> Vec<InlineStyle> {
    let mut styles = vec![];
    if bold { styles.push(InlineStyle::Bold); }
    if italic { styles.push(InlineStyle::Italic); }
    styles
}

pub fn parse_inline(input: &str) -> Vec<InlineText> {
    let mut block: Vec<InlineText> = vec![];
    let mut current_text = String::new();
    let mut chars = input.chars().peekable();
    let mut bold = false;
    let mut italic = false;
    let mut link: Option<LinkState> = None;

    while let Some(ch) = chars.next() {
        match ch {
            '*' if chars.peek() == Some(&'*') && link.is_none() => {
                chars.next();
                flush(&mut block, &mut current_text, actifs(bold, italic));
                bold = !bold;
            }
            '*' if link.is_none() => current_text.push('*'),

            '_' if link.is_none() => {
                flush(&mut block, &mut current_text, actifs(bold, italic));
                italic = !italic;
            }

            // fin de l'url
            ')' => {
                if let Some(LinkState::Url(mut content, url)) = link.take() {
                    flush(&mut block, &mut content, vec![InlineStyle::Link(url)]);
                    current_text.clear();
                }
            }
            // début de l'url
            '(' => {
                if let Some(LinkState::WaitingUrl(content)) = link.take() {
                    link = Some(LinkState::Url(content, String::new()));
                } else {
                    current_text.push(ch);
                }
            }
            // fin du texte du lien
            ']' => {
                if let Some(LinkState::Text(content)) = link.take() {
                    link = Some(LinkState::WaitingUrl(content));
                } else {
                    current_text.push(ch);
                }
            }
            // début du texte du lien
            '[' => {
                flush(&mut block, &mut current_text, actifs(bold, italic));
                link = Some(LinkState::Text(String::new()));
            }

            _ => match link {
                Some(LinkState::Text(ref mut content)) => content.push(ch),
                Some(LinkState::Url(_, ref mut url)) => url.push(ch),
                _ => current_text.push(ch),
            },
        }
    }

    if !current_text.is_empty() {
        block.push(InlineText {
            content: current_text,
            styles: actifs(bold, italic),
        });
    }

    block
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::document::{InlineStyle, InlineText};

    fn texte(content: &str) -> InlineText {
        InlineText { content: content.to_string(), styles: vec![] }
    }

    fn gras(content: &str) -> InlineText {
        InlineText { content: content.to_string(), styles: vec![InlineStyle::Bold] }
    }

    fn italique(content: &str) -> InlineText {
        InlineText { content: content.to_string(), styles: vec![InlineStyle::Italic] }
    }

    fn gras_italique(content: &str) -> InlineText {
        InlineText { content: content.to_string(), styles: vec![InlineStyle::Bold, InlineStyle::Italic] }
    }

    fn lien(content: &str, url: &str) -> InlineText {
        InlineText { content: content.to_string(), styles: vec![InlineStyle::Link(url.to_string())] }
    }

    #[test]
    fn test_texte_simple() {
        assert_eq!(parse_inline("bonjour"), vec![texte("bonjour")]);
    }

    #[test]
    fn test_gras() {
        assert_eq!(
            parse_inline("avant **gras** après"),
            vec![texte("avant "), gras("gras"), texte(" après")]
        );
    }

    #[test]
    fn test_italique() {
        assert_eq!(
            parse_inline("avant _italique_ après"),
            vec![texte("avant "), italique("italique"), texte(" après")]
        );
    }

    #[test]
    fn test_lien() {
        assert_eq!(
            parse_inline("[texte](https://example.com)"),
            vec![lien("texte", "https://example.com")]
        );
    }

    #[test]
    fn test_lien_avec_contexte() {
        assert_eq!(
            parse_inline("voir [doc](https://doc.rs) ici"),
            vec![texte("voir "), lien("doc", "https://doc.rs"), texte(" ici")]
        );
    }

    #[test]
    fn test_etoile_simple_litterale() {
        assert_eq!(parse_inline("a * b"), vec![texte("a * b")]);
    }

    #[test]
    fn test_gras_italique() {
        assert_eq!(
            parse_inline("**_combiné_**"),
            vec![gras_italique("combiné")]
        );
    }
}
