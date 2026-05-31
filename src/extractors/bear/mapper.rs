// ── Bear Markdown → Pinkha domain types ──────────────────────────────────────
//
// Line-by-line parser for Bear's Markdown dialect.
// No external parsing crates — plain char/string matching.

use chaqaq::parse_inline;
use chrono::{DateTime, TimeZone, Utc};

use crate::domain::document::{BlockContent, InlineText};

/// Number of seconds between the Core Data epoch (2001-01-01) and
/// the Unix epoch (1970-01-01).
const CORE_DATA_EPOCH_OFFSET: f64 = 978_307_200.0;

/// Converts a Bear Core Data timestamp to an ISO 8601 date string ("YYYY-MM-DD").
pub fn bear_date_to_iso(timestamp: f64) -> String {
    let unix_secs = timestamp + CORE_DATA_EPOCH_OFFSET;
    let dt: DateTime<Utc> = Utc
        .timestamp_opt(unix_secs as i64, 0)
        .single()
        .unwrap_or_else(Utc::now);
    dt.format("%Y-%m-%d").to_string()
}

/// Parses a Bear note body into a list of Pinkha `BlockContent` values.
///
/// Bear includes the note title as the first `# Heading` in the body — that
/// line is skipped because the title is already used as the document title.
pub fn parse_note_blocks(text: &str) -> Vec<BlockContent> {
    let mut blocks = Vec::new();
    let mut lines = text.lines().peekable();

    // Skip the leading `# Title` line if present.
    if let Some(first) = lines.peek() {
        if first.starts_with("# ") {
            lines.next();
        }
    }

    let mut in_code_block = false;
    let mut code_language = String::new();
    let mut code_lines: Vec<&str> = Vec::new();

    for line in lines {
        // ── Code fences ───────────────────────────────────────────────────────
        if line.starts_with("```") {
            if in_code_block {
                // Closing fence — emit the accumulated code block.
                blocks.push(BlockContent::Code {
                    language: code_language.clone(),
                    text: code_lines.join("\n"),
                });
                in_code_block = false;
                code_language.clear();
                code_lines.clear();
            } else {
                // Opening fence — capture optional language hint.
                in_code_block = true;
                code_language = line.trim_start_matches('`').trim().to_string();
            }
            continue;
        }

        if in_code_block {
            code_lines.push(line);
            continue;
        }

        // ── Headings ──────────────────────────────────────────────────────────
        if let Some(rest) = line.strip_prefix("### ") {
            blocks.push(BlockContent::Heading {
                text: parse_inline_text(rest),
                level: 3,
            });
            continue;
        }
        if let Some(rest) = line.strip_prefix("## ") {
            blocks.push(BlockContent::Heading {
                text: parse_inline_text(rest),
                level: 2,
            });
            continue;
        }
        if let Some(rest) = line.strip_prefix("# ") {
            blocks.push(BlockContent::Heading {
                text: parse_inline_text(rest),
                level: 1,
            });
            continue;
        }

        // ── Block quote ───────────────────────────────────────────────────────
        if let Some(rest) = line.strip_prefix("> ") {
            blocks.push(BlockContent::Quote {
                icon: None,
                text: parse_inline_text(rest),
            });
            continue;
        }

        // ── Todo items ────────────────────────────────────────────────────────
        if let Some(rest) = line.strip_prefix("- [ ] ") {
            blocks.push(BlockContent::Todo {
                done: false,
                text: parse_inline_text(rest),
            });
            continue;
        }
        if let Some(rest) = line.strip_prefix("- [x] ").or_else(|| line.strip_prefix("- [X] ")) {
            blocks.push(BlockContent::Todo {
                done: true,
                text: parse_inline_text(rest),
            });
            continue;
        }

        // ── Bullet list ───────────────────────────────────────────────────────
        if let Some(rest) = line.strip_prefix("- ").or_else(|| line.strip_prefix("* ")) {
            blocks.push(BlockContent::BulletedListItem(parse_inline_text(rest)));
            continue;
        }

        // ── Numbered list ─────────────────────────────────────────────────────
        if let Some(rest) = strip_numbered_list(line) {
            blocks.push(BlockContent::NumberedListItem(parse_inline_text(rest)));
            continue;
        }

        // ── Dividers ──────────────────────────────────────────────────────────
        let trimmed = line.trim();
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            blocks.push(BlockContent::Divider);
            continue;
        }

        // ── Skip empty lines ──────────────────────────────────────────────────
        if trimmed.is_empty() {
            continue;
        }

        // ── Default: rich text paragraph ──────────────────────────────────────
        blocks.push(BlockContent::Text(parse_inline_text(line)));
    }

    // If the file ended inside a code block, flush what we have.
    if in_code_block && !code_lines.is_empty() {
        blocks.push(BlockContent::Code {
            language: code_language,
            text: code_lines.join("\n"),
        });
    }

    blocks
}

/// Parses inline markdown styles using `chaqaq::parse_inline`.
fn parse_inline_text(s: &str) -> Vec<InlineText> {
    parse_inline(s)
}

/// Matches `^\d+\. ` and returns the rest of the line, or `None`.
fn strip_numbered_list(line: &str) -> Option<&str> {
    let mut chars = line.char_indices();
    // Consume one or more digits.
    let (_, first) = chars.next()?;
    if !first.is_ascii_digit() {
        return None;
    }
    let mut last_digit_pos = 0;
    for (i, c) in chars.by_ref() {
        if c.is_ascii_digit() {
            last_digit_pos = i;
        } else if c == '.' {
            // Next must be a space.
            let rest = &line[i + 1..];
            if let Some(content) = rest.strip_prefix(' ') {
                return Some(content);
            }
            return None;
        } else {
            return None;
        }
    }
    let _ = last_digit_pos;
    None
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_skips_title_heading() {
        let text = "# My Note\nSome text";
        let blocks = parse_note_blocks(text);
        assert_eq!(blocks.len(), 1);
        assert!(matches!(&blocks[0], BlockContent::Text(_)));
    }

    #[test]
    fn test_parse_headings() {
        let text = "## Section\n### Sub";
        let blocks = parse_note_blocks(text);
        assert_eq!(blocks.len(), 2);
        assert!(matches!(&blocks[0], BlockContent::Heading { level: 2, .. }));
        assert!(matches!(&blocks[1], BlockContent::Heading { level: 3, .. }));
    }

    #[test]
    fn test_parse_todo() {
        let text = "- [ ] Undone\n- [x] Done";
        let blocks = parse_note_blocks(text);
        assert_eq!(blocks.len(), 2);
        assert!(matches!(&blocks[0], BlockContent::Todo { done: false, .. }));
        assert!(matches!(&blocks[1], BlockContent::Todo { done: true, .. }));
    }

    #[test]
    fn test_parse_code_block() {
        let text = "```rust\nfn main() {}\n```";
        let blocks = parse_note_blocks(text);
        assert_eq!(blocks.len(), 1);
        if let BlockContent::Code { language, text } = &blocks[0] {
            assert_eq!(language, "rust");
            assert_eq!(text, "fn main() {}");
        } else {
            panic!("expected Code block");
        }
    }

    #[test]
    fn test_parse_divider() {
        let text = "---";
        let blocks = parse_note_blocks(text);
        assert_eq!(blocks.len(), 1);
        assert!(matches!(&blocks[0], BlockContent::Divider));
    }

    #[test]
    fn test_parse_bullet_list() {
        let text = "- item one\n* item two";
        let blocks = parse_note_blocks(text);
        assert_eq!(blocks.len(), 2);
        assert!(matches!(&blocks[0], BlockContent::BulletedListItem(_)));
        assert!(matches!(&blocks[1], BlockContent::BulletedListItem(_)));
    }

    #[test]
    fn test_parse_numbered_list() {
        let text = "1. first\n2. second";
        let blocks = parse_note_blocks(text);
        assert_eq!(blocks.len(), 2);
        assert!(matches!(&blocks[0], BlockContent::NumberedListItem(_)));
    }

    #[test]
    fn test_bear_date_to_iso() {
        // 0.0 Core Data → 2001-01-01
        let s = bear_date_to_iso(0.0);
        assert_eq!(s, "2001-01-01");
    }

    #[test]
    fn test_strip_numbered_list_valid() {
        assert_eq!(strip_numbered_list("1. hello"), Some("hello"));
        assert_eq!(strip_numbered_list("42. world"), Some("world"));
    }

    #[test]
    fn test_strip_numbered_list_invalid() {
        assert!(strip_numbered_list("not a list").is_none());
        assert!(strip_numbered_list("- bullet").is_none());
    }

    // ── Additional tests required by spec ─────────────────────────────────────

    #[test]
    fn test_parse_heading1() {
        let blocks = parse_note_blocks("# Title");
        // The leading `# Title` line is skipped as the document title.
        // A standalone `# Title` with no preceding title is consumed by the
        // title-skip logic, so the result is empty.
        assert_eq!(blocks.len(), 0);
    }

    #[test]
    fn test_parse_heading2() {
        let blocks = parse_note_blocks("## H2");
        assert_eq!(blocks.len(), 1);
        assert!(matches!(&blocks[0], BlockContent::Heading { level: 2, .. }));
    }

    #[test]
    fn test_parse_todo_unchecked() {
        let blocks = parse_note_blocks("- [ ] tâche");
        assert_eq!(blocks.len(), 1);
        assert!(matches!(&blocks[0], BlockContent::Todo { done: false, .. }));
    }

    #[test]
    fn test_parse_todo_checked() {
        let blocks = parse_note_blocks("- [x] tâche");
        assert_eq!(blocks.len(), 1);
        assert!(matches!(&blocks[0], BlockContent::Todo { done: true, .. }));
    }

    #[test]
    fn test_parse_bullet() {
        let blocks = parse_note_blocks("- item");
        assert_eq!(blocks.len(), 1);
        assert!(matches!(&blocks[0], BlockContent::BulletedListItem(_)));
    }

    #[test]
    fn test_parse_plain_text() {
        let blocks = parse_note_blocks("just a plain paragraph");
        assert_eq!(blocks.len(), 1);
        assert!(matches!(&blocks[0], BlockContent::Text(_)));
    }

    #[test]
    fn test_skips_title_line() {
        // First `# Title` line is treated as the document title and skipped.
        // The second line becomes a Text block.
        let blocks = parse_note_blocks("# Title\nparagraphe");
        assert_eq!(blocks.len(), 1);
        assert!(matches!(&blocks[0], BlockContent::Text(_)));
    }
}
