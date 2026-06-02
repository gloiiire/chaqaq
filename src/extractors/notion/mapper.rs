// ── Notion → Pinkha mapper ────────────────────────────────────────────────────
//
// Pure mapping functions: no I/O, no side effects.

use super::schema::{
    NotionAnnotations, NotionBlock, NotionPagePropValue, NotionPropertyDef, NotionRichText,
};
use crate::domain::database::{PropertyType, PropertyValue};
use crate::domain::document::{BlockContent, InlineStyle, InlineText};

// ── Database ID extraction ────────────────────────────────────────────────────

/// Normalises a Notion database ID from a full URL or a raw ID.
///
/// Accepts:
/// - `https://www.notion.so/workspace/MyPage-{id}?pvs=4`
/// - `https://notion.so/{id}`
/// - A bare 32-char hex string (with or without dashes).
///
/// Returns the 32-char hex string (no dashes).
pub fn extract_database_id(input: &str) -> String {
    // Strip URL prefix.
    let stripped = input
        .trim_start_matches("https://www.notion.so/")
        .trim_start_matches("https://notion.so/");

    // Drop query-string.
    let without_query = stripped.split('?').next().unwrap_or(stripped);

    // Take the last path component.
    let last_segment = without_query
        .split('/')
        .filter(|s| !s.is_empty())
        .last()
        .unwrap_or(without_query);

    // Find the trailing 32-char hex sequence (UUID without dashes after the last `-`).
    // Notion URLs look like: "My-Page-Title-{32hexchars}" or just the UUID with dashes.
    // Strategy: find a 32-hex run scanning from the right; fall back to stripping dashes.
    let hex_chars: Vec<char> = last_segment
        .chars()
        .filter(|c| c.is_ascii_hexdigit())
        .collect();

    if hex_chars.len() >= 32 {
        // Take the last 32 hex chars (the UUID part in Notion slugs is always at the end).
        hex_chars[hex_chars.len() - 32..].iter().collect()
    } else {
        // Best-effort fallback: strip all non-hex chars.
        last_segment
            .chars()
            .filter(|c| c.is_ascii_hexdigit())
            .collect()
    }
}

// ── Rich text mapping ─────────────────────────────────────────────────────────

/// Maps a slice of Notion rich-text runs to Pinkha `InlineText` items.
///
/// Empty runs (empty `plain_text`) are filtered out.
pub fn map_rich_text(items: &[NotionRichText]) -> Vec<InlineText> {
    items
        .iter()
        .filter(|r| !r.plain_text.is_empty())
        .map(|r| InlineText {
            content: r.plain_text.clone(),
            styles: map_annotations(&r.annotations, r.href.as_deref()),
        })
        .collect()
}

/// Converts Notion text annotations to Pinkha inline styles.
fn map_annotations(ann: &NotionAnnotations, href: Option<&str>) -> Vec<InlineStyle> {
    let mut styles = Vec::new();
    if ann.bold {
        styles.push(InlineStyle::Bold);
    }
    if ann.italic {
        styles.push(InlineStyle::Italic);
    }
    if ann.underline {
        styles.push(InlineStyle::Underline);
    }
    if ann.strikethrough {
        styles.push(InlineStyle::Strikethrough);
    }
    if let Some(color) = map_notion_color(&ann.color) {
        styles.push(InlineStyle::Color(color.to_string()));
    }
    if let Some(url) = href {
        styles.push(InlineStyle::Link(url.to_string()));
    }
    styles
}

/// Converts a Notion colour name to a Pinkha colour name.
///
/// Returns `None` for `"default"` and for `*_background` variants.
fn map_notion_color(c: &str) -> Option<&'static str> {
    // Ignore background colours.
    if c.ends_with("_background") || c == "default" {
        return None;
    }
    match c {
        "red" => Some("red"),
        "pink" => Some("pink"),
        "orange" => Some("orange"),
        "yellow" => Some("yellow"),
        "green" => Some("green"),
        "blue" => Some("blue"),
        "purple" => Some("purple"),
        "brown" => Some("brown"),
        "gray" | "grey" => None,
        _ => None,
    }
}

// ── Block mapping ─────────────────────────────────────────────────────────────

/// Extracts the block-level colour (mapped to a Pinkha colour name) when the
/// Notion block carries one. Returns `None` for `"default"`, unknown colour
/// names, and background variants (`*_background`) — background colours are
/// not yet a first-class concept on `Block`, so we ignore them rather than
/// dropping data into the wrong field.
pub fn map_block_color(block: &NotionBlock) -> Option<String> {
    let raw: &str = match block.type_.as_str() {
        "paragraph" => block.paragraph.as_ref().map(|b| b.color.as_str()),
        "heading_1" => block.heading_1.as_ref().map(|b| b.color.as_str()),
        "heading_2" => block.heading_2.as_ref().map(|b| b.color.as_str()),
        "heading_3" => block.heading_3.as_ref().map(|b| b.color.as_str()),
        "callout" => block.callout.as_ref().map(|b| b.color.as_str()),
        "quote" => block.quote.as_ref().map(|b| b.color.as_str()),
        "to_do" => block.to_do.as_ref().map(|b| b.color.as_str()),
        "bulleted_list_item" => block.bulleted_list_item.as_ref().map(|b| b.color.as_str()),
        "numbered_list_item" => block.numbered_list_item.as_ref().map(|b| b.color.as_str()),
        "code" => block.code.as_ref().map(|b| b.color.as_str()),
        _ => None,
    }?;
    map_notion_color(raw).map(str::to_owned)
}

/// Converts a Notion block to a Pinkha `BlockContent`.
///
/// Returns `None` for block types that have no Pinkha equivalent (e.g. images,
/// toggle, column_list, …).
pub fn map_block(block: &NotionBlock) -> Option<BlockContent> {
    match block.type_.as_str() {
        "paragraph" => {
            let rt = block.paragraph.as_ref()?;
            Some(BlockContent::Text(map_rich_text(&rt.rich_text)))
        }
        "heading_1" => {
            let rt = block.heading_1.as_ref()?;
            Some(BlockContent::Heading {
                text: map_rich_text(&rt.rich_text),
                level: 1,
            })
        }
        "heading_2" => {
            let rt = block.heading_2.as_ref()?;
            Some(BlockContent::Heading {
                text: map_rich_text(&rt.rich_text),
                level: 2,
            })
        }
        "heading_3" => {
            let rt = block.heading_3.as_ref()?;
            Some(BlockContent::Heading {
                text: map_rich_text(&rt.rich_text),
                level: 3,
            })
        }
        "callout" => {
            let cb = block.callout.as_ref()?;
            let icon = cb.icon.as_ref().and_then(|i| {
                if i.type_ == "emoji" {
                    i.emoji.clone()
                } else {
                    None
                }
            });
            Some(BlockContent::Quote {
                icon,
                text: map_rich_text(&cb.rich_text),
            })
        }
        "quote" => {
            let rt = block.quote.as_ref()?;
            Some(BlockContent::Quote {
                icon: None,
                text: map_rich_text(&rt.rich_text),
            })
        }
        "to_do" => {
            let td = block.to_do.as_ref()?;
            Some(BlockContent::Todo {
                text: map_rich_text(&td.rich_text),
                done: td.checked,
            })
        }
        "bulleted_list_item" => {
            let rt = block.bulleted_list_item.as_ref()?;
            Some(BlockContent::BulletedListItem(map_rich_text(&rt.rich_text)))
        }
        "numbered_list_item" => {
            let rt = block.numbered_list_item.as_ref()?;
            Some(BlockContent::NumberedListItem(map_rich_text(&rt.rich_text)))
        }
        "code" => {
            let cb = block.code.as_ref()?;
            let text = cb
                .rich_text
                .iter()
                .map(|r| r.plain_text.as_str())
                .collect::<Vec<_>>()
                .join("");
            Some(BlockContent::Code {
                language: cb.language.clone(),
                text,
            })
        }
        "divider" => Some(BlockContent::Divider),
        _ => None,
    }
}

// ── Property type mapping ─────────────────────────────────────────────────────

/// Converts a Notion property definition to a Pinkha `PropertyType`.
pub fn map_property_type(def: &NotionPropertyDef) -> PropertyType {
    match def.type_.as_str() {
        "title" => PropertyType::Title,
        "rich_text" => PropertyType::Text,
        "number" => PropertyType::Number,
        "checkbox" => PropertyType::Checkbox,
        "date" | "created_time" | "last_edited_time" => PropertyType::Date,
        "url" => PropertyType::Url,
        "select" => {
            let options = def
                .select
                .as_ref()
                .map(|s| s.options.iter().map(|o| o.name.clone()).collect())
                .unwrap_or_default();
            PropertyType::Selection(options)
        }
        "multi_select" => {
            let options = def
                .multi_select
                .as_ref()
                .map(|s| s.options.iter().map(|o| o.name.clone()).collect())
                .unwrap_or_default();
            PropertyType::SelectionMultiple(options)
        }
        _ => PropertyType::Text,
    }
}

/// Converts a Notion page property value to a Pinkha `PropertyValue`.
///
/// Returns `None` for `Unknown` variants (property types not yet modelled).
pub fn map_property_value(val: &NotionPagePropValue) -> Option<PropertyValue> {
    match val {
        NotionPagePropValue::Title { title } => Some(PropertyValue::Title(map_rich_text(title))),
        NotionPagePropValue::RichText { rich_text } => {
            let text: String = rich_text.iter().map(|r| r.plain_text.as_str()).collect();
            Some(PropertyValue::Text(text))
        }
        NotionPagePropValue::Number { number } => {
            Some(PropertyValue::Number(number.unwrap_or(0.0)))
        }
        NotionPagePropValue::Select { select } => Some(PropertyValue::Selection(
            select.as_ref().map(|s| s.name.clone()),
        )),
        NotionPagePropValue::MultiSelect { multi_select } => {
            let names = multi_select.iter().map(|s| s.name.clone()).collect();
            Some(PropertyValue::SelectionMultiple(names))
        }
        NotionPagePropValue::Date { date } => {
            let s = date.as_ref().map(|d| d.start.clone()).unwrap_or_default();
            Some(PropertyValue::Date(s))
        }
        NotionPagePropValue::Checkbox { checkbox } => Some(PropertyValue::Checkbox(*checkbox)),
        NotionPagePropValue::Url { url } => {
            Some(PropertyValue::Url(url.clone().unwrap_or_default()))
        }
        NotionPagePropValue::CreatedTime { created_time } => {
            Some(PropertyValue::Date(created_time.clone()))
        }
        NotionPagePropValue::Unknown => None,
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_database_id_from_url() {
        let url =
            "https://www.notion.so/workspace/My-Page-Title-1234567890abcdef1234567890abcdef?pvs=4";
        let id = extract_database_id(url);
        assert_eq!(id, "1234567890abcdef1234567890abcdef");
    }

    #[test]
    fn test_extract_database_id_bare() {
        let id = extract_database_id("1234567890abcdef1234567890abcdef");
        assert_eq!(id, "1234567890abcdef1234567890abcdef");
    }

    #[test]
    fn test_extract_database_id_with_dashes() {
        let id = extract_database_id("12345678-90ab-cdef-1234-567890abcdef");
        assert_eq!(id, "1234567890abcdef1234567890abcdef");
    }

    #[test]
    fn test_map_rich_text_filters_empty() {
        let items = vec![
            NotionRichText {
                plain_text: "".to_string(),
                annotations: NotionAnnotations::default(),
                href: None,
            },
            NotionRichText {
                plain_text: "hello".to_string(),
                annotations: NotionAnnotations::default(),
                href: None,
            },
        ];
        let result = map_rich_text(&items);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].content, "hello");
    }

    #[test]
    fn test_map_notion_color_default_is_none() {
        assert!(map_notion_color("default").is_none());
        assert!(map_notion_color("red_background").is_none());
        assert!(map_notion_color("gray").is_none());
    }

    #[test]
    fn test_map_notion_color_known() {
        assert_eq!(map_notion_color("red"), Some("red"));
        assert_eq!(map_notion_color("purple"), Some("purple"));
    }

    #[test]
    fn test_map_property_value_checkbox() {
        let val = NotionPagePropValue::Checkbox { checkbox: true };
        assert_eq!(
            map_property_value(&val),
            Some(PropertyValue::Checkbox(true))
        );
    }

    #[test]
    fn test_map_property_value_unknown_is_none() {
        let val = NotionPagePropValue::Unknown;
        assert!(map_property_value(&val).is_none());
    }

    // ── Block mapping tests ───────────────────────────────────────────────────

    /// Builds a `RichTextBlock` with a single plain-text run.
    fn rt_block(text: &str) -> super::super::schema::RichTextBlock {
        use super::super::schema::RichTextBlock;
        RichTextBlock {
            color: "default".into(),
            rich_text: vec![NotionRichText {
                plain_text: text.to_string(),
                annotations: NotionAnnotations::default(),
                href: None,
            }],
        }
    }

    /// Helper: build a minimal `NotionBlock` for a given type with one rich-text run.
    fn make_rt_block(type_: &str) -> NotionBlock {
        NotionBlock {
            id: "fake-id".to_string(),
            type_: type_.to_string(),
            has_children: false,
            paragraph: if type_ == "paragraph" {
                Some(rt_block("hello"))
            } else {
                None
            },
            heading_1: if type_ == "heading_1" {
                Some(rt_block("hello"))
            } else {
                None
            },
            heading_2: if type_ == "heading_2" {
                Some(rt_block("hello"))
            } else {
                None
            },
            heading_3: if type_ == "heading_3" {
                Some(rt_block("hello"))
            } else {
                None
            },
            callout: None,
            quote: if type_ == "quote" {
                Some(rt_block("hello"))
            } else {
                None
            },
            to_do: None,
            bulleted_list_item: if type_ == "bulleted_list_item" {
                Some(rt_block("hello"))
            } else {
                None
            },
            numbered_list_item: if type_ == "numbered_list_item" {
                Some(rt_block("hello"))
            } else {
                None
            },
            code: None,
        }
    }

    #[test]
    fn test_map_block_paragraph() {
        let block = make_rt_block("paragraph");
        let result = map_block(&block);
        assert!(matches!(
            result,
            Some(crate::domain::document::BlockContent::Text(_))
        ));
    }

    #[test]
    fn test_map_block_heading1() {
        let block = make_rt_block("heading_1");
        let result = map_block(&block);
        assert!(matches!(
            result,
            Some(crate::domain::document::BlockContent::Heading { level: 1, .. })
        ));
    }

    #[test]
    fn test_map_block_bulleted() {
        let block = make_rt_block("bulleted_list_item");
        let result = map_block(&block);
        assert!(matches!(
            result,
            Some(crate::domain::document::BlockContent::BulletedListItem(_))
        ));
    }

    #[test]
    fn test_map_block_code() {
        use super::super::schema::CodeBlock;
        let rt = NotionRichText {
            plain_text: "fn main() {}".to_string(),
            annotations: NotionAnnotations::default(),
            href: None,
        };
        let block = NotionBlock {
            id: "fake-id".to_string(),
            type_: "code".to_string(),
            has_children: false,
            paragraph: None,
            heading_1: None,
            heading_2: None,
            heading_3: None,
            callout: None,
            quote: None,
            to_do: None,
            bulleted_list_item: None,
            numbered_list_item: None,
            code: Some(CodeBlock {
                rich_text: vec![rt],
                language: "rust".to_string(),
                color: "default".into(),
            }),
        };
        let result = map_block(&block);
        match result {
            Some(crate::domain::document::BlockContent::Code { language, text }) => {
                assert_eq!(language, "rust");
                assert_eq!(text, "fn main() {}");
            }
            _ => panic!("expected Code block"),
        }
    }

    #[test]
    fn test_map_block_unknown() {
        let block = NotionBlock {
            id: "fake-id".to_string(),
            type_: "image".to_string(),
            has_children: false,
            paragraph: None,
            heading_1: None,
            heading_2: None,
            heading_3: None,
            callout: None,
            quote: None,
            to_do: None,
            bulleted_list_item: None,
            numbered_list_item: None,
            code: None,
        };
        assert!(map_block(&block).is_none());
    }

    // ── Property type mapping tests ───────────────────────────────────────────

    #[test]
    fn test_map_property_type_number() {
        use super::super::schema::NotionPropertyDef;
        use crate::domain::database::PropertyType;
        let def = NotionPropertyDef {
            id: "abc".to_string(),
            name: "Score".to_string(),
            type_: "number".to_string(),
            select: None,
            multi_select: None,
        };
        assert_eq!(map_property_type(&def), PropertyType::Number);
    }

    // ── Additional block mapping tests ────────────────────────────────────────

    #[test]
    fn test_map_block_todo_checked() {
        use super::super::schema::TodoBlock;
        let rt = NotionRichText {
            plain_text: "task".to_string(),
            annotations: NotionAnnotations::default(),
            href: None,
        };
        let block = NotionBlock {
            id: "fake-id".to_string(),
            type_: "to_do".to_string(),
            has_children: false,
            paragraph: None,
            heading_1: None,
            heading_2: None,
            heading_3: None,
            callout: None,
            quote: None,
            to_do: Some(TodoBlock {
                rich_text: vec![rt],
                checked: true,
                color: "default".into(),
            }),
            bulleted_list_item: None,
            numbered_list_item: None,
            code: None,
        };
        let result = map_block(&block);
        assert!(matches!(
            result,
            Some(crate::domain::document::BlockContent::Todo { done: true, .. })
        ));
    }

    #[test]
    fn test_map_block_todo_unchecked() {
        use super::super::schema::TodoBlock;
        let rt = NotionRichText {
            plain_text: "task".to_string(),
            annotations: NotionAnnotations::default(),
            href: None,
        };
        let block = NotionBlock {
            id: "fake-id".to_string(),
            type_: "to_do".to_string(),
            has_children: false,
            paragraph: None,
            heading_1: None,
            heading_2: None,
            heading_3: None,
            callout: None,
            quote: None,
            to_do: Some(TodoBlock {
                rich_text: vec![rt],
                checked: false,
                color: "default".into(),
            }),
            bulleted_list_item: None,
            numbered_list_item: None,
            code: None,
        };
        let result = map_block(&block);
        assert!(matches!(
            result,
            Some(crate::domain::document::BlockContent::Todo { done: false, .. })
        ));
    }

    #[test]
    fn test_map_block_callout_with_emoji() {
        use super::super::schema::{CalloutBlock, CalloutIcon};
        let rt = NotionRichText {
            plain_text: "fire".to_string(),
            annotations: NotionAnnotations::default(),
            href: None,
        };
        let block = NotionBlock {
            id: "fake-id".to_string(),
            type_: "callout".to_string(),
            has_children: false,
            paragraph: None,
            heading_1: None,
            heading_2: None,
            heading_3: None,
            callout: Some(CalloutBlock {
                rich_text: vec![rt],
                icon: Some(CalloutIcon {
                    type_: "emoji".to_string(),
                    emoji: Some("🔥".to_string()),
                }),
                color: "default".into(),
            }),
            quote: None,
            to_do: None,
            bulleted_list_item: None,
            numbered_list_item: None,
            code: None,
        };
        let result = map_block(&block);
        match result {
            Some(crate::domain::document::BlockContent::Quote { icon, .. }) => {
                assert_eq!(icon, Some("🔥".to_string()));
            }
            _ => panic!("expected Quote block"),
        }
    }

    #[test]
    fn test_map_block_callout_without_icon() {
        use super::super::schema::CalloutBlock;
        let rt = NotionRichText {
            plain_text: "note".to_string(),
            annotations: NotionAnnotations::default(),
            href: None,
        };
        let block = NotionBlock {
            id: "fake-id".to_string(),
            type_: "callout".to_string(),
            has_children: false,
            paragraph: None,
            heading_1: None,
            heading_2: None,
            heading_3: None,
            callout: Some(CalloutBlock {
                rich_text: vec![rt],
                icon: None,
                color: "default".into(),
            }),
            quote: None,
            to_do: None,
            bulleted_list_item: None,
            numbered_list_item: None,
            code: None,
        };
        let result = map_block(&block);
        match result {
            Some(crate::domain::document::BlockContent::Quote { icon, .. }) => {
                // No icon in the Notion block → icon is None (no default injected by mapper).
                assert!(icon.is_none());
            }
            _ => panic!("expected Quote block"),
        }
    }

    #[test]
    fn test_map_block_quote() {
        use super::super::schema::RichTextBlock;
        let block = NotionBlock {
            id: "fake-id".to_string(),
            type_: "quote".to_string(),
            has_children: false,
            paragraph: None,
            heading_1: None,
            heading_2: None,
            heading_3: None,
            callout: None,
            quote: Some(RichTextBlock {
                rich_text: vec![NotionRichText {
                    plain_text: "wisdom".to_string(),
                    annotations: NotionAnnotations::default(),
                    href: None,
                }],
                color: "default".into(),
            }),
            to_do: None,
            bulleted_list_item: None,
            numbered_list_item: None,
            code: None,
        };
        let result = map_block(&block);
        match result {
            Some(crate::domain::document::BlockContent::Quote { icon, text }) => {
                assert!(icon.is_none());
                assert_eq!(text.len(), 1);
                assert_eq!(text[0].content, "wisdom");
            }
            _ => panic!("expected Quote block"),
        }
    }

    #[test]
    fn test_map_block_divider() {
        let block = NotionBlock {
            id: "fake-id".to_string(),
            type_: "divider".to_string(),
            has_children: false,
            paragraph: None,
            heading_1: None,
            heading_2: None,
            heading_3: None,
            callout: None,
            quote: None,
            to_do: None,
            bulleted_list_item: None,
            numbered_list_item: None,
            code: None,
        };
        let result = map_block(&block);
        assert!(matches!(
            result,
            Some(crate::domain::document::BlockContent::Divider)
        ));
    }

    // ── Additional property value tests ───────────────────────────────────────

    #[test]
    fn test_map_property_value_select_none() {
        // Select with no chosen option → Selection(None).
        let val = NotionPagePropValue::Select { select: None };
        assert_eq!(
            map_property_value(&val),
            Some(crate::domain::database::PropertyValue::Selection(None))
        );
    }

    #[test]
    fn test_map_property_value_multiselect() {
        use super::super::schema::SelectValue;
        let val = NotionPagePropValue::MultiSelect {
            multi_select: vec![
                SelectValue {
                    name: "a".to_string(),
                },
                SelectValue {
                    name: "b".to_string(),
                },
            ],
        };
        match map_property_value(&val) {
            Some(crate::domain::database::PropertyValue::SelectionMultiple(names)) => {
                assert_eq!(names, vec!["a", "b"]);
            }
            _ => panic!("expected SelectionMultiple"),
        }
    }

    #[test]
    fn test_map_property_value_url() {
        let val = NotionPagePropValue::Url {
            url: Some("https://example.com".to_string()),
        };
        assert_eq!(
            map_property_value(&val),
            Some(crate::domain::database::PropertyValue::Url(
                "https://example.com".to_string()
            ))
        );
    }

    // ── Additional rich text mapping tests ────────────────────────────────────

    #[test]
    fn test_map_rich_text_bold() {
        let items = vec![NotionRichText {
            plain_text: "bold text".to_string(),
            annotations: NotionAnnotations {
                bold: true,
                ..NotionAnnotations::default()
            },
            href: None,
        }];
        let result = map_rich_text(&items);
        assert_eq!(result.len(), 1);
        assert!(
            result[0]
                .styles
                .contains(&crate::domain::document::InlineStyle::Bold)
        );
    }

    #[test]
    fn test_map_rich_text_color() {
        let items = vec![NotionRichText {
            plain_text: "red text".to_string(),
            annotations: NotionAnnotations {
                color: "red".to_string(),
                ..NotionAnnotations::default()
            },
            href: None,
        }];
        let result = map_rich_text(&items);
        assert_eq!(result.len(), 1);
        assert!(
            result[0]
                .styles
                .contains(&crate::domain::document::InlineStyle::Color(
                    "red".to_string()
                ))
        );
    }

    #[test]
    fn test_map_rich_text_link() {
        let url = "https://example.com";
        let items = vec![NotionRichText {
            plain_text: "click me".to_string(),
            annotations: NotionAnnotations::default(),
            href: Some(url.to_string()),
        }];
        let result = map_rich_text(&items);
        assert_eq!(result.len(), 1);
        assert!(
            result[0]
                .styles
                .contains(&crate::domain::document::InlineStyle::Link(url.to_string()))
        );
    }

    // ── extract_database_id with workspace slug ───────────────────────────────

    #[test]
    fn test_extract_database_id_with_workspace() {
        // URL format: notion.so/myworkspace/Title-{32hexchars}
        let url = "https://www.notion.so/myworkspace/Title-abc123def456abc123def456abc123de";
        let id = extract_database_id(url);
        assert_eq!(id, "abc123def456abc123def456abc123de");
    }

    // ── map_block_color ──────────────────────────────────────────────────────

    fn paragraph_block_with_color(color: &str) -> NotionBlock {
        use super::super::schema::RichTextBlock;
        NotionBlock {
            id: "b1".into(),
            type_: "paragraph".into(),
            has_children: false,
            paragraph: Some(RichTextBlock {
                rich_text: vec![],
                color: color.into(),
            }),
            heading_1: None,
            heading_2: None,
            heading_3: None,
            callout: None,
            quote: None,
            to_do: None,
            bulleted_list_item: None,
            numbered_list_item: None,
            code: None,
        }
    }

    #[test]
    fn map_block_color_extracts_red_from_paragraph() {
        let block = paragraph_block_with_color("red");
        assert_eq!(map_block_color(&block).as_deref(), Some("red"));
    }

    #[test]
    fn map_block_color_returns_none_for_default() {
        let block = paragraph_block_with_color("default");
        assert!(map_block_color(&block).is_none());
    }

    #[test]
    fn map_block_color_ignores_background_variants() {
        // Backgrounds aren't yet a first-class concept on Block.color — we
        // deliberately drop them rather than misclassify as text colour.
        let block = paragraph_block_with_color("red_background");
        assert!(map_block_color(&block).is_none());
    }

    #[test]
    fn map_block_color_returns_none_for_unsupported_block_type() {
        let block = NotionBlock {
            id: "b1".into(),
            type_: "unsupported_type".into(),
            has_children: false,
            paragraph: None,
            heading_1: None,
            heading_2: None,
            heading_3: None,
            callout: None,
            quote: None,
            to_do: None,
            bulleted_list_item: None,
            numbered_list_item: None,
            code: None,
        };
        assert!(map_block_color(&block).is_none());
    }
}
