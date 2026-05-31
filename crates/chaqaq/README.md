# chaqaq

Rich text editor engine for Rust.

Inline styles · Unicode-safe cursor & selection · Undo/redo · Markdown parser

[![Crates.io](https://img.shields.io/crates/v/chaqaq.svg)](https://crates.io/crates/chaqaq)
[![License: MIT OR Apache-2.0](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg)](#license)

## Features

- **`InlineText` / `InlineStyle`** — serializable text model (serde)
- **`RichText`** — in-memory flat string + style spans; all indices are char positions (not byte offsets) — safe with multi-byte Unicode
- **`EditorState`** — cursor, selection, `insert`, `delete_before/after`, `move_left/right`, `toggle_style`
- **`History`** — undo/redo via the Command pattern, configurable capacity (default 1 000 levels)
- **`parse_inline`** — markdown shorthand parser: `**bold**`, `_italic_`, `__underline__`, `~~strike~~`, `{color:text}`, `[label](url)`, and combinations

## Quick start

```toml
[dependencies]
chaqaq = "0.1"
```

```rust
use chaqaq::{parse_inline, RichText, EditorState, InlineStyle};
use chaqaq::commands::{History, Insert};

let spans = parse_inline("**bold** and _italic_");
let rt = RichText::from(&spans);
let mut editor = EditorState::new(rt);

// undo/redo
let mut hist = History::default();
hist.apply(Box::new(Insert::new(editor.cursor, '!')), &mut editor);
hist.undo(&mut editor);

// style toggle on selection
editor.select(0..4);
editor.toggle_style(InlineStyle::Bold);

// back to Vec<InlineText> for persistence
let inlines: Vec<_> = Vec::from(&editor.text);
```

## Inline syntax

| Input | Result |
|---|---|
| `**bold**` | Bold |
| `_italic_` | Italic |
| `__underline__` | Underline |
| `~~strike~~` | Strikethrough |
| `{red:text}` | Color("red") |
| `[label](url)` | Link(url) |
| `**_bold italic_**` | Bold + Italic |

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache 2.0](LICENSE-APACHE), at your option.
