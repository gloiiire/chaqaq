use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum InlineStyle {
    Bold,
    Underline,
    Strikethrough,
    Link(String),
    Italic,
    Color(String),
    // etc…
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InlineText {
    pub content: String,
    #[serde(alias = "style")]
    pub styles: Vec<InlineStyle>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum BlockContent {
    Text(Vec<InlineText>),
    Heading {
        text: Vec<InlineText>,
        level: u8,
    },
    Quote {
        icon: Option<String>,
        text: Vec<InlineText>,
    },
    Divider,
    Todo {
        text: Vec<InlineText>,
        done: bool,
    },
    Breadcrumb,
    Database {
        id: Uuid,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Block {
    pub id: Uuid,
    pub content: BlockContent,
    pub children: Vec<Block>,
}

impl Block {
    pub fn new(content: BlockContent) -> Self {
        Block {
            id: Uuid::new_v4(),
            content,
            children: vec![],
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DocumentMeta {
    pub id: Uuid,
    pub cover: Option<String>,
    pub title: Vec<InlineText>,
    /// Timestamp ISO 8601 de la dernière modification — géré par l'infrastructure.
    /// Empty si le backend ne le fournit pas (JsonStore, mock).
    #[serde(default)]
    pub updated_at: String,
    /// Timestamp ISO 8601 de création — setté à l'INSERT, jamais modifié.
    /// Empty si le backend ne le fournit pas (JsonStore, mock).
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Document {
    pub id: Uuid,
    pub cover: Option<String>,
    pub title: Vec<InlineText>,
    pub blocks: Vec<Block>,
}

impl Document {
    pub fn new(title: Vec<InlineText>) -> Self {
        Self {
            id: Uuid::new_v4(),
            title,
            cover: None,
            blocks: vec![],
        }
    }

    pub fn add_block(&mut self, content: BlockContent) {
        self.blocks.push(Block::new(content));
    }
}
