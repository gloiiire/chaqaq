use serde::{Deserialize, Serialize};

/// Inline style applied to a text segment.
///
/// Styles can be combined on the same [`InlineText`] by listing multiple values.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum InlineStyle {
    /// **Bold** text.
    Bold,
    /// __Underlined__ text.
    Underline,
    /// ~~Strikethrough~~ text.
    Strikethrough,
    /// Hyperlink. The inner `String` is the URL.
    Link(String),
    /// _Italic_ text.
    Italic,
    /// Colored text. The inner `String` is the color name (e.g. `"red"`).
    Color(String),
}

/// A run of text sharing the same set of [`InlineStyle`]s.
///
/// A `Vec<InlineText>` is the canonical serializable representation of a
/// styled paragraph. [`RichText`](crate::RichText) is the in-memory editing
/// form; the two convert to each other without loss.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InlineText {
    /// Plain text content of this run.
    pub content: String,
    /// Styles applied to the whole run.
    pub styles: Vec<InlineStyle>,
}
