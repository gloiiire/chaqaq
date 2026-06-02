// ── Notion API v1 — serde types ───────────────────────────────────────────────
//
// Only the shapes actually consumed by the extractor are modelled here.
// Unknown fields are silently ignored (serde default behaviour).

use serde::Deserialize;
use std::collections::HashMap;

// ── Rich text ─────────────────────────────────────────────────────────────────

/// Text annotations applied to a rich-text run.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct NotionAnnotations {
    #[serde(default)]
    pub bold: bool,
    #[serde(default)]
    pub italic: bool,
    #[serde(default)]
    pub strikethrough: bool,
    #[serde(default)]
    pub underline: bool,
    /// Colour name as returned by the API (e.g. `"red"`, `"default"`).
    #[serde(default = "default_color")]
    pub color: String,
}

fn default_color() -> String {
    "default".to_string()
}

/// A single run of rich text as returned by the Notion API.
#[derive(Debug, Clone, Deserialize)]
pub struct NotionRichText {
    pub plain_text: String,
    #[serde(default)]
    pub annotations: NotionAnnotations,
    /// Optional hyperlink applied to the entire run.
    pub href: Option<String>,
}

// ── Database schema ───────────────────────────────────────────────────────────

/// Schema of a Notion database (property definitions + title).
#[derive(Debug, Clone, Deserialize)]
pub struct NotionDatabaseSchema {
    pub id: String,
    pub title: Vec<NotionRichText>,
    pub properties: HashMap<String, NotionPropertyDef>,
}

impl NotionDatabaseSchema {
    /// Concatenates the plain-text runs of the database title.
    pub fn title_plain(&self) -> String {
        self.title.iter().map(|r| r.plain_text.as_str()).collect()
    }
}

/// Definition of a single column in a Notion database.
#[derive(Debug, Clone, Deserialize)]
pub struct NotionPropertyDef {
    pub id: String,
    pub name: String,
    #[serde(rename = "type")]
    pub type_: String,
    pub select: Option<NotionSelectConfig>,
    pub multi_select: Option<NotionSelectConfig>,
}

/// Dropdown option list for `select` and `multi_select` properties.
#[derive(Debug, Clone, Deserialize)]
pub struct NotionSelectConfig {
    pub options: Vec<NotionSelectOption>,
}

/// A single dropdown option.
#[derive(Debug, Clone, Deserialize)]
pub struct NotionSelectOption {
    pub name: String,
}

// ── Query response ────────────────────────────────────────────────────────────

/// Paginated response from `POST /v1/databases/{id}/query`.
#[derive(Debug, Deserialize)]
pub struct NotionQueryResponse {
    pub results: Vec<NotionPageResult>,
    pub has_more: bool,
    pub next_cursor: Option<String>,
}

/// A single page (row) returned by a database query.
#[derive(Debug, Deserialize)]
pub struct NotionPageResult {
    pub id: String,
    pub properties: HashMap<String, NotionPagePropValue>,
    /// Cover image of the page. `None` when the user didn't pick one.
    #[serde(default)]
    pub cover: Option<NotionPageCover>,
    /// Page icon (emoji or external image). `None` when not set.
    #[serde(default)]
    pub icon: Option<NotionPageIcon>,
}

/// Cover image returned by the Notion API. Two variants depending on the
/// source (Notion-hosted file vs external URL); we only care about the URL.
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum NotionPageCover {
    External { external: NotionExternalFile },
    File { file: NotionHostedFile },
    #[serde(other)]
    Unknown,
}

impl NotionPageCover {
    /// Returns the URL pointing at the cover image, regardless of where it is
    /// hosted. `None` for the catch-all `Unknown` variant.
    pub fn url(&self) -> Option<&str> {
        match self {
            Self::External { external } => Some(&external.url),
            Self::File { file } => Some(&file.url),
            Self::Unknown => None,
        }
    }
}

/// Page icon — the Notion API returns either an emoji or an image (external
/// URL or Notion-hosted file).
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum NotionPageIcon {
    Emoji { emoji: String },
    External { external: NotionExternalFile },
    File { file: NotionHostedFile },
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Deserialize)]
pub struct NotionExternalFile {
    pub url: String,
}

#[derive(Debug, Deserialize)]
pub struct NotionHostedFile {
    pub url: String,
}

/// Property value variants returned inside a page result.
///
/// Internally tagged on the `"type"` field; unknown types fall through to
/// `Unknown` via `#[serde(other)]` on the unit variant.
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum NotionPagePropValue {
    Title {
        title: Vec<NotionRichText>,
    },
    RichText {
        rich_text: Vec<NotionRichText>,
    },
    Number {
        number: Option<f64>,
    },
    Select {
        select: Option<SelectValue>,
    },
    MultiSelect {
        multi_select: Vec<SelectValue>,
    },
    Date {
        date: Option<DateValue>,
    },
    Checkbox {
        checkbox: bool,
    },
    Url {
        url: Option<String>,
    },
    CreatedTime {
        created_time: String,
    },
    #[serde(other)]
    Unknown,
}

/// A selected option value (single or multi-select).
#[derive(Debug, Deserialize)]
pub struct SelectValue {
    pub name: String,
}

/// A date property value.
#[derive(Debug, Deserialize)]
pub struct DateValue {
    pub start: String,
}

// ── Blocks response ───────────────────────────────────────────────────────────

/// Paginated response from `GET /v1/blocks/{id}/children`.
#[derive(Debug, Deserialize)]
pub struct NotionBlocksResponse {
    pub results: Vec<NotionBlock>,
    pub has_more: bool,
    pub next_cursor: Option<String>,
}

/// A single block returned by the blocks endpoint.
#[derive(Debug, Deserialize)]
pub struct NotionBlock {
    pub id: String,
    #[serde(rename = "type")]
    pub type_: String,
    /// Whether this block has nested child blocks that must be fetched separately.
    #[serde(default)]
    pub has_children: bool,
    pub paragraph: Option<RichTextBlock>,
    pub heading_1: Option<RichTextBlock>,
    pub heading_2: Option<RichTextBlock>,
    pub heading_3: Option<RichTextBlock>,
    pub callout: Option<CalloutBlock>,
    pub quote: Option<RichTextBlock>,
    pub to_do: Option<TodoBlock>,
    pub bulleted_list_item: Option<RichTextBlock>,
    pub numbered_list_item: Option<RichTextBlock>,
    pub code: Option<CodeBlock>,
}

/// Block content that carries only a rich-text array (paragraph, headings, quote, list items).
#[derive(Debug, Deserialize)]
pub struct RichTextBlock {
    pub rich_text: Vec<NotionRichText>,
    /// Block-level colour (`"default"`, `"red"`, `"red_background"`, …).
    /// Mapped to `Block.color` at import — backgrounds are ignored for now.
    #[serde(default = "default_color")]
    pub color: String,
}

/// Callout block — rich text plus an optional icon.
#[derive(Debug, Deserialize)]
pub struct CalloutBlock {
    pub rich_text: Vec<NotionRichText>,
    pub icon: Option<CalloutIcon>,
    #[serde(default = "default_color")]
    pub color: String,
}

/// Icon attached to a callout.
#[derive(Debug, Deserialize)]
pub struct CalloutIcon {
    #[serde(rename = "type")]
    pub type_: String,
    pub emoji: Option<String>,
}

/// To-do block — rich text plus checked state.
#[derive(Debug, Deserialize)]
pub struct TodoBlock {
    pub rich_text: Vec<NotionRichText>,
    pub checked: bool,
    #[serde(default = "default_color")]
    pub color: String,
}

/// Code block — rich text (the code content) plus language hint.
#[derive(Debug, Deserialize)]
pub struct CodeBlock {
    pub rich_text: Vec<NotionRichText>,
    pub language: String,
    #[serde(default = "default_color")]
    pub color: String,
}
