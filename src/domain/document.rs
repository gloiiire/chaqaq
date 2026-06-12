pub use chaqaq::{InlineStyle, InlineText};
use serde::{Deserialize, Deserializer, Serialize};
use uuid::Uuid;

/// Maps a JSON `null` or missing field to `String::default()` (empty),
/// otherwise expects a normal string. Used by `DocumentMeta`'s
/// timestamp fields so JSON files written by [`crate::domain::document::Document`]
/// — whose timestamps are `Option<String>` and serialise to `null` when
/// `None` — can still be re-read into the non-optional `String` typed
/// meta view without serde rejecting the row.
fn deserialize_string_or_null<'de, D>(d: D) -> Result<String, D::Error>
where
    D: Deserializer<'de>,
{
    Ok(Option::<String>::deserialize(d)?.unwrap_or_default())
}

/// Content variant of a block — determines how it is rendered and edited.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum BlockContent {
    /// Rich-text paragraph.
    Text(Vec<InlineText>),
    /// Section heading at the given level (1 = largest).
    Heading {
        /// Rich-text content of the heading.
        text: Vec<InlineText>,
        /// Heading level: 1, 2, or 3.
        level: u8,
    },
    /// Block quote, optionally prefixed by an emoji icon (used for callouts).
    Quote {
        /// Optional emoji icon displayed before the text.
        icon: Option<String>,
        /// Rich-text content.
        text: Vec<InlineText>,
    },
    /// Horizontal divider line — carries no text.
    Divider,
    /// Checkbox task item.
    Todo {
        /// Rich-text label.
        text: Vec<InlineText>,
        /// Whether the task has been completed.
        done: bool,
    },
    /// Breadcrumb navigation placeholder — no editable content.
    Breadcrumb,
    /// Embedded database reference.
    Database {
        /// ID of the referenced `Database`.
        id: Uuid,
    },
    /// Bulleted list item (rendered with a bullet point •).
    BulletedListItem(Vec<InlineText>),
    /// Numbered list item (rendered with an auto-incremented index 1., 2., …).
    NumberedListItem(Vec<InlineText>),
    /// Code block with optional syntax-highlighting language identifier.
    Code {
        /// Programming language hint for syntax highlighting (e.g. `"swift"`, `"rust"`).
        /// Empty string means no language specified.
        language: String,
        /// Raw source code — no inline styles, whitespace preserved.
        text: String,
    },
    /// Reference to a child page (Notion-style "child_page" block).
    /// Renders as a clickable row pointing to another Document. The child
    /// document remains autonomous (its own title, blocks, color, …); this
    /// block only places it inline at a chosen position in the parent.
    Page {
        /// ID of the referenced child `Document`.
        id: Uuid,
    },
    /// Rich card preview for a single URL (Notion-style "web bookmark").
    /// Renders with the destination's title / description / image fetched
    /// from OpenGraph tags for external URLs; `pinkha://doc/{uuid}` URLs
    /// resolve instantly against the local store and show the target
    /// document's title + icon. The block's content is just the URL —
    /// metadata is recomputed at render time so the card stays fresh.
    Embed {
        /// Destination URL. Can be a `pinkha://doc/{uuid}` for internal
        /// references or any `http(s)://` URL for external bookmarks.
        url: String,
    },
}

/// A node in a document's block tree — may contain nested child blocks.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Block {
    /// Unique block identifier.
    pub id: Uuid,
    /// Content variant and its data.
    pub content: BlockContent,
    /// Nested child blocks (recursive structure).
    pub children: Vec<Block>,
    /// Block-level text color name (e.g. `"red"`, `"blue"`). When set, applies
    /// to every span that does NOT carry its own [`InlineStyle::Color`] —
    /// inline color overrides block color at render time. `None` means the
    /// block inherits the default theme color.
    ///
    /// `#[serde(default)]` keeps the field backward-compatible with documents
    /// serialised before this field existed (they decode as `None`).
    #[serde(default)]
    pub color: Option<String>,
    /// Block-level *background* color name (e.g. `"red"`, `"blue"`).
    /// When set, the editor paints a soft tinted band behind the
    /// whole block (Craft / Notion highlight style). Independent
    /// from [`Block::color`] — the foreground color can be `None`
    /// while the background is set and vice versa. `None` means no
    /// background. `#[serde(default)]` keeps backward compatibility.
    #[serde(default)]
    pub background_color: Option<String>,
    /// Per-block writing direction override. Values: `"ltr"`,
    /// `"rtl"`, or `None` to inherit the document-level setting
    /// (which itself defaults to the system locale). Lets a single
    /// Arabic paragraph live inside an otherwise LTR document, or
    /// vice versa. `#[serde(default)]` for backward compatibility.
    #[serde(default)]
    pub text_direction: Option<String>,
}

impl Block {
    /// Creates a new leaf block with no children, no color, and a freshly
    /// generated UUID.
    pub fn new(content: BlockContent) -> Self {
        Block {
            id: Uuid::new_v4(),
            content,
            children: vec![],
            color: None,
            background_color: None,
            text_direction: None,
        }
    }
}

/// Lightweight document descriptor returned by list operations (no blocks loaded).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DocumentMeta {
    /// Document identifier.
    pub id: Uuid,
    /// Optional cover image URL or emoji.
    pub cover: Option<String>,
    /// Optional page icon (emoji or filename). Mirrors `Document.icon`.
    #[serde(default)]
    pub icon: Option<String>,
    /// Rich-text title.
    pub title: Vec<InlineText>,
    /// ISO 8601 timestamp of the last modification, managed by the infrastructure layer.
    /// Empty when the backend does not provide it (JsonStore, mock).
    /// `deserialize_with` tolerates an explicit `null` from a JSON
    /// document whose Document-side timestamp is `None` — without it,
    /// `JsonStore.list()` silently drops every doc that was natively
    /// created in-app (those serialise `created_at: null`).
    #[serde(default, deserialize_with = "deserialize_string_or_null")]
    pub updated_at: String,
    /// ISO 8601 creation timestamp, set at INSERT and never modified.
    /// Empty when the backend does not provide it (JsonStore, mock).
    /// Same `null → ""` tolerance as `updated_at` above.
    #[serde(default, deserialize_with = "deserialize_string_or_null")]
    pub created_at: String,
    /// User-editable publish timestamp. Defaults to `created_at` at
    /// insert (so untouched docs behave like before), but the user
    /// can override it from the doc toolbar. Empty string on legacy
    /// metas (pre-field) is treated as "fall back to `created_at`"
    /// by the sort path.
    #[serde(default, deserialize_with = "deserialize_string_or_null")]
    pub published_at: String,
    /// Folder this document belongs to. None = root level.
    #[serde(default)]
    pub folder_id: Option<Uuid>,
    /// Parent document for Notion-style page-in-page hierarchy. `None` means
    /// the document is a root page; otherwise it is a child page reachable
    /// either by tapping its [`BlockContent::Page`] block inside the parent,
    /// or by navigating through the breadcrumbs from any descendant.
    #[serde(default)]
    pub parent_doc_id: Option<Uuid>,
}

impl From<&Document> for DocumentMeta {
    fn from(doc: &Document) -> Self {
        Self {
            id: doc.id,
            cover: doc.cover.clone(),
            icon: doc.icon.clone(),
            title: doc.title.clone(),
            updated_at: String::new(),
            created_at: String::new(),
            published_at: doc.published_at.clone(),
            folder_id: doc.folder_id,
            parent_doc_id: doc.parent_doc_id,
        }
    }
}

/// A document: a title, an optional cover, and an ordered list of top-level blocks.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Document {
    /// Document identifier.
    pub id: Uuid,
    /// Optional cover image URL or emoji.
    pub cover: Option<String>,
    /// Page icon. Small visual identifier shown next to the title — an emoji
    /// (`"📕"`), a local filename inside the covers directory, or a remote
    /// URL. Distinct from `cover` which is the big banner image at the top.
    /// `#[serde(default)]` keeps backward compatibility with documents
    /// serialised before this field existed.
    #[serde(default)]
    pub icon: Option<String>,
    /// Rich-text title.
    pub title: Vec<InlineText>,
    /// Top-level blocks (each may have nested children).
    pub blocks: Vec<Block>,
    /// Folder this document belongs to. None = root level.
    #[serde(default)]
    pub folder_id: Option<Uuid>,
    /// Parent document for Notion-style page-in-page hierarchy. `None` means
    /// the document is a root page; otherwise it is a child page placed
    /// inside its parent via a [`BlockContent::Page`] block.
    #[serde(default)]
    pub parent_doc_id: Option<Uuid>,
    /// Read-only flag. When `true`, the editor disables every interactive
    /// element (blocks become non-editable, the keyboard accessory hides,
    /// the FAB and "+New block" footer go away). Used by data-extract
    /// imports (Notion/Bear/Craft) to default new documents to a safe view
    /// mode so the user reads first and unlocks before editing imported
    /// content. `#[serde(default)]` keeps backward compat with documents
    /// saved before this field existed.
    #[serde(default)]
    pub locked: bool,
    /// Optional override for the document's `created_at` timestamp at
    /// **first save**. When `Some`, the store uses this value (RFC 3339
    /// string) for the initial INSERT instead of `now()`. Used by
    /// importers (Notion / Bear / Craft) so the imported doc keeps the
    /// original platform's creation date, not the import-time wall
    /// clock. `None` for natively-created docs — they get `now()` as
    /// usual. After the first save this field is irrelevant (the SQLite
    /// row's `created_at` is immutable).
    #[serde(default)]
    pub created_at: Option<String>,
    /// Per-document accent color name (e.g. `"red"`, `"teal"`). When
    /// `Some`, the editor renders its chrome (toolbar, FAB, cursor,
    /// selection lozenge, etc.) in this color instead of the
    /// app-wide accent from settings. `None` means the document
    /// inherits the global accent. Same naming scheme as
    /// [`Block::color`] — the rendering layer maps the name to a
    /// concrete `UIColor` / `Color`. `#[serde(default)]` keeps
    /// backward compatibility with pre-feature documents.
    #[serde(default)]
    pub accent_color: Option<String>,
    /// Document-level writing direction. Values: `"ltr"`, `"rtl"`,
    /// or `None` to let the system locale decide. Acts as the
    /// default for every block; individual blocks can still override
    /// via [`Block::text_direction`]. `#[serde(default)]` for
    /// backward compatibility.
    #[serde(default)]
    pub text_direction: Option<String>,
    /// Per-document theme name (`"original"`, `"tranquille"`,
    /// `"papier"`, `"gras"`, `"calme"`, `"attention"`). When
    /// `Some`, the editor paints the doc background + text in the
    /// matching palette regardless of the app-wide setting. `None`
    /// inherits from `AppSettings.theme`. Same naming scheme as
    /// `accent_color`. `#[serde(default)]` for backward compatibility.
    #[serde(default)]
    pub theme: Option<String>,
    /// User-editable publish timestamp. Defaults to `created_at`
    /// at the SQLite insert path (see `SqliteDocumentStore`), but
    /// the user can override it from the doc toolbar to make the
    /// doc surface as if it had been published on a different
    /// date — useful for backdated articles. Empty string on
    /// legacy rows is treated as "follow `created_at`" by the sort
    /// path. `#[serde(default)]` keeps backward compat.
    #[serde(default)]
    pub published_at: String,
}

impl Document {
    /// Creates a new empty document with a freshly generated UUID.
    pub fn new(title: Vec<InlineText>) -> Self {
        Self {
            id: Uuid::new_v4(),
            title,
            cover: None,
            icon: None,
            blocks: vec![],
            folder_id: None,
            parent_doc_id: None,
            locked: false,
            created_at: None,
            accent_color: None,
            text_direction: None,
            theme: None,
            published_at: String::new(),
        }
    }

    /// Appends a new block at the end of the top-level block list.
    pub fn add_block(&mut self, content: BlockContent) {
        self.blocks.push(Block::new(content));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn block_new_starts_without_color() {
        let block = Block::new(BlockContent::Divider);
        assert!(block.color.is_none());
    }

    #[test]
    fn block_serde_round_trip_preserves_color() {
        let mut block = Block::new(BlockContent::Divider);
        block.color = Some("orange".into());
        let json = serde_json::to_string(&block).unwrap();
        let decoded: Block = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.color.as_deref(), Some("orange"));
        assert_eq!(decoded.id, block.id);
    }

    /// Documents serialised before the `color` field existed must still decode
    /// — `#[serde(default)]` on the new field makes the absence equivalent to
    /// `None`. Regression guard: removing the attribute would break every
    /// existing user's data file.
    #[test]
    fn block_decodes_legacy_json_without_color_field() {
        let id = Uuid::new_v4();
        let legacy_json = format!(r#"{{"id":"{id}","content":"Divider","children":[]}}"#);
        let decoded: Block = serde_json::from_str(&legacy_json).unwrap();
        assert_eq!(decoded.id, id);
        assert!(decoded.color.is_none());
        assert!(decoded.children.is_empty());
    }
}
