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
            let icon = cb
                .icon
                .as_ref()
                .and_then(|i| if i.type_ == "emoji" { i.emoji.clone() } else { None });
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
        NotionPagePropValue::Title { title } => {
            Some(PropertyValue::Title(map_rich_text(title)))
        }
        NotionPagePropValue::RichText { rich_text } => {
            let text: String = rich_text.iter().map(|r| r.plain_text.as_str()).collect();
            Some(PropertyValue::Text(text))
        }
        NotionPagePropValue::Number { number } => {
            Some(PropertyValue::Number(number.unwrap_or(0.0)))
        }
        NotionPagePropValue::Select { select } => {
            Some(PropertyValue::Selection(select.as_ref().map(|s| s.name.clone())))
        }
        NotionPagePropValue::MultiSelect { multi_select } => {
            let names = multi_select.iter().map(|s| s.name.clone()).collect();
            Some(PropertyValue::SelectionMultiple(names))
        }
        NotionPagePropValue::Date { date } => {
            let s = date.as_ref().map(|d| d.start.clone()).unwrap_or_default();
            Some(PropertyValue::Date(s))
        }
        NotionPagePropValue::Checkbox { checkbox } => {
            Some(PropertyValue::Checkbox(*checkbox))
        }
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
        let url = "https://www.notion.so/workspace/My-Page-Title-1234567890abcdef1234567890abcdef?pvs=4";
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
        assert_eq!(map_property_value(&val), Some(PropertyValue::Checkbox(true)));
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
            paragraph: if type_ == "paragraph" { Some(rt_block("hello")) } else { None },
            heading_1: if type_ == "heading_1" { Some(rt_block("hello")) } else { None },
            heading_2: if type_ == "heading_2" { Some(rt_block("hello")) } else { None },
            heading_3: if type_ == "heading_3" { Some(rt_block("hello")) } else { None },
            callout: None,
            quote: if type_ == "quote" { Some(rt_block("hello")) } else { None },
            to_do: None,
            bulleted_list_item: if type_ == "bulleted_list_item" { Some(rt_block("hello")) } else { None },
            numbered_list_item: if type_ == "numbered_list_item" { Some(rt_block("hello")) } else { None },
            code: None,
        }
    }

    #[test]
    fn test_map_block_paragraph() {
        let block = make_rt_block("paragraph");
        let result = map_block(&block);
        assert!(matches!(result, Some(crate::domain::document::BlockContent::Text(_))));
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
        use crate::domain::database::PropertyType;
        use super::super::schema::NotionPropertyDef;
        let def = NotionPropertyDef {
            id: "abc".to_string(),
            name: "Score".to_string(),
            type_: "number".to_string(),
            select: None,
            multi_select: None,
        };
        assert_eq!(map_property_type(&def), PropertyType::Number);
    }
}
