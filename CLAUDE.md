# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
cargo run     # alias: r
cargo build   # alias: cb
cargo check   # alias: cc
cargo test
```

## Architecture

**chaqaq** is a Rust document engine (Notion-like). The core model and main pipeline:

```
parser::parse_inline(str) → Vec<InlineText>   (inline text with styles)
      ↓
document::{Block, Document}                   (block tree, serializable via serde)
      ↓
storage::{save_document, load_document, …}    (JSON files in ~/iCloud Drive/…/documents/)
```

### `src/document.rs` — data model
- `InlineStyle`: Bold, Italic, Underline, Color(String), Link(String)
- `InlineText { content: String, styles: Vec<InlineStyle> }` — leaf unit of all rich text
- `BlockContent`: Text, Heading { level }, Quote { icon }, Todo { done }, Divider, Breadcrumb, Database
- `Block { id: Uuid, content: BlockContent, children: Vec<Block> }` — recursive tree node
- `Document { id, cover, title: Vec<InlineText>, blocks: Vec<Block> }`

### `src/parser.rs` — inline Markdown-like parser
State machine over `chars().peekable()`. Recognises:
- `**text**` → Bold
- `_text_` → Italic
- `[text](url)` → Link

Internal `ParserState` drives `LinkState` sub-machine for the `[…](…)` syntax. The `flush()` helper drains `current_text` into the result vec with the current styles.

### `src/storage.rs` — persistence
Reads/writes JSON files under `~/iCloud Drive/~/documents/`. The path is hardcoded in `get_documents_app_dir()`; documents are stored as `<uuid>.json`. The `documents/` directory in the repo root holds sample files.

## Code style
- Commentaires en français
- Pas de `unwrap()` — utiliser `?` à la place
- `flush()` pour vider le buffer courant dans le résultat

## Notes
- `main.rs` est un point d'entrée scratch/démo ; la vraie logique est dans les modules.
- `#![allow(dead_code)]` intentionnel tant que l'API se construit.
- JSON sur disque utilise `style` (ancien) alors que la struct utilise `styles` — un `#[serde(rename)]` sera nécessaire pour charger les anciens fichiers.
- Pour les tests, ajouter `#[derive(PartialEq)]` sur `InlineText` et `InlineStyle` (requis pour `assert_eq!`).
