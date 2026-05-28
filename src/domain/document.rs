use uuid::Uuid;
use serde::{Serialize, Deserialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum InlineStyle {
    Bold,
    Underline,
    Link(String),
    Italic,
    Color(String),
    // etc…
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InlineText {
    pub content: String,
    pub styles: Vec<InlineStyle>,
}

#[derive(Debug, Serialize, Deserialize)]
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
    Database,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Block {
    pub id: Uuid,
    pub content: BlockContent,
    pub children: Vec<Block>,
}

impl Block {
    fn new(content: BlockContent) -> Self {
        Block {
            id: Uuid::new_v4(),
            content,
            children: vec![],
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct DocumentMeta {
    pub id: Uuid,
    pub cover: Option<String>,
    pub title: Vec<InlineText>,
}

impl From<&Document> for DocumentMeta {
    fn from(doc: &Document) -> Self {
        Self {
            id: doc.id,
            cover: doc.cover.clone(),
            title: doc.title.clone(),
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
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

    fn get_block(&self, id: Uuid) -> Option<&Block> {
        for block in self.blocks.iter() {
            if block.id == id {
                return Some(block);
            }
        }
        None
    }
    fn get_mut_block(&mut self, id: Uuid) -> Option<&mut Block> {
        for block in self.blocks.iter_mut() {
            if block.id == id {
                return Some(block);
            }
        }
        None
    }
    pub fn add_block(&mut self, content: BlockContent) {
        self.blocks.push(Block::new(content));
    }
}