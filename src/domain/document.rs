pub use chaqaq::{InlineStyle, InlineText};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

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
}

impl Block {
    /// Creates a new leaf block with no children and a freshly generated UUID.
    pub fn new(content: BlockContent) -> Self {
        Block {
            id: Uuid::new_v4(),
            content,
            children: vec![],
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
    /// Rich-text title.
    pub title: Vec<InlineText>,
    /// ISO 8601 timestamp of the last modification, managed by the infrastructure layer.
    /// Empty when the backend does not provide it (JsonStore, mock).
    #[serde(default)]
    pub updated_at: String,
    /// ISO 8601 creation timestamp, set at INSERT and never modified.
    /// Empty when the backend does not provide it (JsonStore, mock).
    #[serde(default)]
    pub created_at: String,
}

impl From<&Document> for DocumentMeta {
    fn from(doc: &Document) -> Self {
        Self {
            id: doc.id,
            cover: doc.cover.clone(),
            title: doc.title.clone(),
            updated_at: String::new(),
            created_at: String::new(),
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
    /// Rich-text title.
    pub title: Vec<InlineText>,
    /// Top-level blocks (each may have nested children).
    pub blocks: Vec<Block>,
}

impl Document {
    /// Creates a new empty document with a freshly generated UUID.
    pub fn new(title: Vec<InlineText>) -> Self {
        Self {
            id: Uuid::new_v4(),
            title,
            cover: None,
            blocks: vec![],
        }
    }

    /// Appends a new block at the end of the top-level block list.
    pub fn add_block(&mut self, content: BlockContent) {
        self.blocks.push(Block::new(content));
    }
}
