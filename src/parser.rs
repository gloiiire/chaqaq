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
    let mut result: Vec<InlineText> = vec![];
    let mut current_text = String::new();
    let mut chars = input.chars().peekable();
    let mut parser_state = ParserState::Normal;

    while let Some(ch) = chars.next() {
        match ch {
            '*' => {
                if chars.peek() == Some(&'*') && parser_state == ParserState::Bold {
                    chars.next();
                    flush(&mut result, &mut current_text, vec![InlineStyle::Bold]);
                    parser_state = ParserState::Normal;
                } else if chars.peek() == Some(&'*') {
                    chars.next();
                    flush(&mut result, &mut current_text, vec![]);
                    parser_state = ParserState::Bold;
                } else {
                    current_text.push('*');
                }
            }
            
            '_' => {
                if parser_state == ParserState::Italic {
                    flush(&mut result, &mut current_text, vec![InlineStyle::Italic]);
                    parser_state = ParserState::Normal;
                } else {
                    flush(&mut result, &mut current_text, vec![]);
                    parser_state = ParserState::Italic;
                }
            }
            
            ')' => {
                if let ParserState::Link(LinkState::Url(mut content, url)) = parser_state {
                    flush(
                        &mut result,
                        &mut content,
                        vec![InlineStyle::Link(url.clone())],
                    );
                    parser_state = ParserState::Normal;
                }
            }
            '(' => {
                if let ParserState::Link(LinkState::WaitingUrl(content)) = parser_state {
                    parser_state = ParserState::Link(LinkState::Url(content, String::new()));
                }
            }
            ']' => {
                if let ParserState::Link(LinkState::Text(content)) = parser_state {
                    parser_state = ParserState::Link(LinkState::WaitingUrl(content));
                }
            }
            '[' => {}

            _ => {
                current_text.push(ch);
            }
        }
    }
    if !current_text.is_empty() {
        result.push(InlineText {
            content: current_text,
            styles: vec![],
        });
    }

    result
}
