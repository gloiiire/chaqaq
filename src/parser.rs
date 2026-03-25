#![allow(dead_code)]
use crate::document::{InlineStyle, InlineText};

#[derive(PartialEq)]
enum ParserState {
    Normal,
    Bold,
    Italic,
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

    while let Some(c) = chars.next() {
        match c {
            star if star == '*' => {
                if chars.peek() == Some(&star) && parser_state == ParserState::Bold {
                    chars.next();
                    flush(&mut result, &mut current_text, vec![InlineStyle::Bold]);
                    parser_state = ParserState::Normal;
                } else if chars.peek() == Some(&star) {
                    chars.next();
                    flush(&mut result, &mut current_text, vec![]);
                    parser_state = ParserState::Bold;
                } else {
                    current_text.push(star);
                }
            }
            underscore if underscore == '_' => {
                if parser_state == ParserState::Italic {
                    flush(&mut result, &mut current_text, vec![InlineStyle::Italic]);
                    parser_state = ParserState::Normal;
                } else {
                    flush(&mut result, &mut current_text, vec![]);
                    parser_state = ParserState::Italic;
                }
            }
            _ => {
                current_text.push(c);
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
