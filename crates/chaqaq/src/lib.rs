//! # chaqaq
//!
//! Rich text editor engine for Rust — inline styles, Unicode-safe cursor and selection,
//! undo/redo via the Command pattern, and a markdown shorthand parser.
//!
//! ## Core types
//!
//! - [`InlineText`] / [`InlineStyle`] — the serializable text model
//! - [`RichText`] + [`Span`] — the in-memory editing representation (char indices, not bytes)
//! - [`EditorState`] — cursor, selection, and style toggling
//! - [`History`] + [`Command`] — undo/redo with configurable capacity
//! - [`parse_inline`] — parse markdown shorthands into `Vec<InlineText>`
//!
//! ## Quick start
//!
//! ```rust
//! use chaqaq::{parse_inline, RichText, EditorState, InlineStyle};
//! use chaqaq::commands::{History, Insert};
//!
//! let spans = parse_inline("**bold** and _italic_");
//! let rt = RichText::from(&spans);
//! let mut editor = EditorState::new(rt);
//!
//! let mut hist = History::default();
//! hist.apply(Box::new(Insert::new(editor.cursor, '!')), &mut editor);
//!
//! editor.select(0..4);
//! editor.toggle_style(InlineStyle::Bold);
//! ```

pub mod commands;
mod document;
mod editor;
mod parser;
mod rich_text;

pub use commands::{ApplyStyle, Command, Delete, History, Insert};
pub use document::{InlineStyle, InlineText};
pub use editor::EditorState;
pub use parser::parse_inline;
pub use rich_text::{RichText, Span};
