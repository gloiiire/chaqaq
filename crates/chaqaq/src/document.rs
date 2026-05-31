use serde::{Deserialize, Serialize};

/// Style applicable à un segment de texte inline.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum InlineStyle {
    Bold,
    Underline,
    Strikethrough,
    Link(String),
    Italic,
    Color(String),
}

/// Fragment de texte avec ses styles associés.
/// La conversion `Vec<InlineText> ↔ RichText` est sans perte.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InlineText {
    pub content: String,
    pub styles: Vec<InlineStyle>,
}
