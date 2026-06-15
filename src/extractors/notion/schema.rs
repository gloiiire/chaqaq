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
    /// Optional hyperlink applied to the entire run. Notion fills this for
    /// plain text runs that carry a `[label](url)` link; for mention runs
    /// the linked page reference lives in the `mention` field instead.
    pub href: Option<String>,
    /// Run kind — `"text"` or `"mention"`. We use it to recover the page
    /// id from a `mention.page` payload when href is null (the typical
    /// shape for an inline `@PageName` reference). Defaults to `"text"`
    /// so older serialised data (no field) keeps decoding.
    #[serde(rename = "type", default = "default_run_type")]
    pub run_type: String,
    /// Body of a `mention` run. Only the page variant is materialised
    /// — everything else (`user`, `date`, `book`, …) decodes into
    /// `Unknown` via `#[serde(other)]`.
    #[serde(default)]
    pub mention: Option<NotionMention>,
}

fn default_run_type() -> String {
    "text".to_string()
}

/// Body of a Notion `mention` rich-text run. Only page references are
/// surfaced — other mention kinds fall through to `Unknown` and are
/// ignored by the importer (rendered as plain text).
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum NotionMention {
    Page {
        page: NotionMentionPage,
    },
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NotionMentionPage {
    pub id: String,
}

// ── Search response (book picker) ─────────────────────────────────────────

/// Paginated response from `POST /v1/search` filtered to books. Only the
/// fields the picker UI needs are deserialised — the actual book schema
/// is fetched lazily by the existing per-import flow.
#[derive(Debug, Deserialize)]
pub struct NotionSearchResponse {
    pub results: Vec<NotionDatabaseSearchHit>,
    pub has_more: bool,
    pub next_cursor: Option<String>,
}

/// Paginated response from `POST /v1/search` filtered to `object: "page"`.
/// Used by the v2025 picker walker to enumerate every page the
/// integration can see, then dive into each one's blocks to surface
/// nested `child_database` blocks that the `object: book` search
/// doesn't find on its own.
#[derive(Debug, Deserialize)]
pub struct NotionPageSearchResponse {
    pub results: Vec<NotionPageSearchHit>,
    pub has_more: bool,
    pub next_cursor: Option<String>,
}

/// Minimal page hit — only the fields the walker actually uses.
#[derive(Debug, Deserialize)]
pub struct NotionPageSearchHit {
    pub id: String,
    #[serde(default)]
    pub last_edited_time: String,
}

/// Search response for the v2025-09-03 API when filtered to
/// `object: "data_source"`. Same envelope as `NotionSearchResponse`
/// but with a distinct hit shape — kept as a separate struct so the
/// legacy parser stays untouched (Open/Closed : extend, don't
/// modify).
#[derive(Debug, Deserialize)]
pub struct NotionDataSourceSearchResponse {
    pub results: Vec<NotionDataSourceSearchHit>,
    pub has_more: bool,
    pub next_cursor: Option<String>,
}

/// A single data-source hit. Notion's 2025-09-03 API introduced
/// data sources as a first-class object — each multi-source book
/// has one data_source per tab. The wrapping book's UUID lives
/// in `parent.book_id`. For single-source DBs there's still a
/// 1:1 mapping ; either way we want the book id for our import
/// path (`/v1/books/{id}/query` keeps working under the legacy
/// version header).
#[derive(Debug, Deserialize)]
pub struct NotionDataSourceSearchHit {
    pub id: String,
    /// Plain-text data-source name (data sources don't carry a
    /// rich-text title like books do — Notion ships it as a
    /// single string).
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub icon: Option<NotionPageIcon>,
    #[serde(default)]
    pub last_edited_time: String,
    pub parent: NotionDataSourceParent,
}

/// Discriminated-union parent ref. Almost every data source has a
/// `book_id` parent — the catch-all `Unknown` covers any
/// future parent shapes Notion might introduce without breaking
/// our deserialize.
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum NotionDataSourceParent {
    BookId {
        book_id: String,
    },
    #[serde(other)]
    Unknown,
}

/// A single book returned by the search endpoint. Carries enough data for
/// the picker to render a row (title + icon + freshness) without doing extra
/// API calls.
#[derive(Debug, Deserialize)]
pub struct NotionDatabaseSearchHit {
    pub id: String,
    /// Rich-text title runs. Concatenate `plain_text` for display.
    #[serde(default)]
    pub title: Vec<NotionRichText>,
    /// Page icon (emoji or image). `None` when the user didn't set one.
    #[serde(default)]
    pub icon: Option<NotionPageIcon>,
    /// ISO 8601 timestamp of the last edit. Used to sort recent-first in the
    /// picker. `#[serde(default)]` keeps things resilient against API
    /// variations.
    #[serde(default)]
    pub last_edited_time: String,
    /// URL inside notion.so. Useful for "open in Notion" links from the
    /// picker, though we don't surface that yet.
    #[serde(default)]
    pub url: String,
}

// ── Book schema ───────────────────────────────────────────────────────────

/// Schema of a Notion book (property definitions + title + chrome).
#[derive(Debug, Clone, Deserialize)]
pub struct NotionDatabaseSchema {
    pub id: String,
    pub title: Vec<NotionRichText>,
    /// Rich-text description shown under the title in Notion. Empty
    /// when the user didn't set one ; `#[serde(default)]` so older
    /// fixtures keep parsing.
    #[serde(default)]
    pub description: Vec<NotionRichText>,
    /// Book cover banner. Same shape as a page cover — Notion
    /// uses the identical type at both levels.
    #[serde(default)]
    pub cover: Option<NotionPageCover>,
    /// Book icon (emoji or external image).
    #[serde(default)]
    pub icon: Option<NotionPageIcon>,
    pub properties: HashMap<String, NotionPropertyDef>,
}

impl NotionDatabaseSchema {
    /// Concatenates the plain-text runs of the book title.
    pub fn title_plain(&self) -> String {
        self.title.iter().map(|r| r.plain_text.as_str()).collect()
    }
}

/// Definition of a single column in a Notion book.
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

/// Paginated response from `POST /v1/books/{id}/query`.
#[derive(Debug, Deserialize)]
pub struct NotionQueryResponse {
    pub results: Vec<NotionPageResult>,
    pub has_more: bool,
    pub next_cursor: Option<String>,
}

/// A single page (row) returned by a book query.
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
    /// RFC 3339 timestamp set by Notion when the page was created.
    /// Forwarded into the Pinkha doc's `created_at` at import so the
    /// imported note keeps its real creation date instead of the
    /// import wall-clock time. `#[serde(default)]` to stay
    /// forward-compatible with any older fixtures missing the field.
    #[serde(default)]
    pub created_time: String,
}

/// Cover image returned by the Notion API. Two variants depending on the
/// source (Notion-hosted file vs external URL); we only care about the URL.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum NotionPageCover {
    External {
        external: NotionExternalFile,
    },
    File {
        file: NotionHostedFile,
    },
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
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum NotionPageIcon {
    Emoji {
        emoji: String,
    },
    External {
        external: NotionExternalFile,
    },
    File {
        file: NotionHostedFile,
    },
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NotionExternalFile {
    pub url: String,
}

#[derive(Debug, Clone, Deserialize)]
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
    /// Child-page block payload — present when `type_ == "child_page"`. The
    /// block's `id` doubles as the embedded child page's Notion id, fetched
    /// separately during import to materialise the child leaf.
    pub child_page: Option<ChildPageBlock>,
    /// Child-book block payload — present when `type_ == "child_database"`.
    /// The block's own `id` is the wrapping book's Notion id, used by
    /// the v2025 picker walker to surface nested DBs that the
    /// `object: book` search doesn't enumerate on its own.
    pub child_database: Option<ChildDatabaseBlock>,
    /// Link-to-page block payload — present when `type_ == "link_to_page"`.
    /// References an existing page (or book) by id; the importer maps
    /// it to an inline link that the mention-rewriting pass resolves to a
    /// `pinkha://doc/{uuid}` when the target belongs to the same import.
    pub link_to_page: Option<LinkToPageBlock>,
}

/// Body of a `link_to_page` block. Exactly one of the two ids is set,
/// discriminated by the payload's own `type` field which we don't need —
/// presence is enough.
#[derive(Debug, Deserialize)]
pub struct LinkToPageBlock {
    pub page_id: Option<String>,
    pub book_id: Option<String>,
}

/// Body of a `child_database` block — Notion only inlines the title
/// in the block stream. The rest of the schema is fetched by the
/// existing import flow via `GET /v1/books/{block_id}`.
#[derive(Debug, Deserialize)]
pub struct ChildDatabaseBlock {
    /// Defensive `#[serde(default)]` — Notion has been observed to
    /// ship `null` titles for unnamed child books ; without
    /// this, the whole page-block response would fail to
    /// deserialize and the walker would silently drop the page.
    #[serde(default)]
    pub title: String,
}

/// Body of a `child_page` block — only carries the static title shown inline.
/// The actual page content lives at the URL formed from the parent block's
/// id, which the importer fetches recursively.
#[derive(Debug, Deserialize)]
pub struct ChildPageBlock {
    pub title: String,
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
