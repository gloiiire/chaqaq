#![allow(dead_code)]
use crate::document::{InlineStyle, InlineText};

#[derive(PartialEq)]
enum LinkState {
    Text(String),
    WaitingUrl(String),
    Url(String, String),
}

#[derive(PartialEq)]
enum ParserState {
    Normal,
    Bold,
    Italic,
    Link(LinkState),
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

pub fn parse_inline(input: &str) -> Vec<InlineText> {
    let mut block: Vec<InlineText> = vec![];
    let mut current_text = String::new();
    let mut chars = input.chars().peekable();
    let mut parser_state = ParserState::Normal;

    while let Some(ch) = chars.next() {
        match ch {
            '*' => match chars.peek() {
                ch if ch == Some(&'*') && parser_state == ParserState::Bold => {
                    chars.next();
                    flush(&mut block, &mut current_text, vec![InlineStyle::Bold]);
                    parser_state = ParserState::Normal;
                }
                ch if ch == Some(&'*') => {
                    chars.next();
                    flush(&mut block, &mut current_text, vec![]);
                    parser_state = ParserState::Bold;
                }
                _ => {
                    current_text.push('*');
                }
            },

            '_' => match parser_state {
                ParserState::Italic => {
                    flush(&mut block, &mut current_text, vec![InlineStyle::Italic]);
                    parser_state = ParserState::Normal;
                }
                _ => {
                    flush(&mut block, &mut current_text, vec![]);
                    parser_state = ParserState::Italic;
                }
            },

            // fin de l'url
            ')' => {
                if let ParserState::Link(LinkState::Url(mut content, url)) = parser_state {
                    flush(
                        &mut block,
                        &mut content,
                        vec![InlineStyle::Link(url.clone())],
                    );
                    current_text.clear();
                    parser_state = ParserState::Normal;
                }
            } // debut de l'url
            '(' => match parser_state {
                ParserState::Link(LinkState::WaitingUrl(content)) => {
                    parser_state = ParserState::Link(LinkState::Url(content, String::new()))
                }
                _ => current_text.push(ch),
            }, //fin du text
            ']' => match parser_state {
                ParserState::Link(LinkState::Text(content)) => {
                    parser_state = ParserState::Link(LinkState::WaitingUrl(content))
                }
                _ => current_text.push(ch),
            }, // debut du text
            '[' => {
                parser_state = ParserState::Link(LinkState::Text(String::new()));
                current_text.push(ch);
            }

            _ => {
                match parser_state {
                    ParserState::Link(LinkState::Text(ref mut content)) => content.push(ch),
                    ParserState::Link(LinkState::Url(_, ref mut url)) => url.push(ch),
                    _ => current_text.push(ch),
                }
                // current_text.push(ch);
            }
        }
    }
    if !current_text.is_empty() {
        block.push(InlineText {
            content: current_text,
            styles: vec![],
        });
    }

    block
}
