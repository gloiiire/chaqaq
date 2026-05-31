# pinkha

A personal notes app combining the fluency of Craft and the structure of Notion — pure Rust core.

[![CI](https://github.com/gloiiire/pinkha/actions/workflows/ci.yml/badge.svg)](https://github.com/gloiiire/pinkha/actions/workflows/ci.yml)
[![chaqaq on crates.io](https://img.shields.io/crates/v/chaqaq.svg)](https://crates.io/crates/chaqaq)

> Status: **complete Rust backend** (208 tests) · **functional SwiftUI UI** (rich text, undo/redo, toolbar pill, drag & drop) · **compiled XCFramework** iOS + Mac · **[`chaqaq`](https://crates.io/crates/chaqaq) v0.1.0 published on crates.io**

---

## Vision

pinkha is a note-taking app with two ambitions:

- **Beauty and fluency** à la Craft: native rendering, rich blocks, inline styles
- **Structure and power** à la Notion: databases, views, filters, relations, rollups

The project is entirely written in Rust for the core. Target platforms: iPhone, iPad, Mac.

---

## Workspace

The repo is a **Cargo workspace** with two crates:

| Crate | Description |
|---|---|
| [`chaqaq`](https://crates.io/crates/chaqaq) | Core rich text editor — published on crates.io (MIT OR Apache-2.0) |
| `pinkha` | Full application — depends on `chaqaq` |

### chaqaq — open source crate

`chaqaq` is the inline editing engine extracted from pinkha, usable independently in any Rust project:

```toml
[dependencies]
chaqaq = "0.1"
```

It provides:
- `InlineStyle` / `InlineText` — serializable rich text model
- `RichText` + `Span` — editing representation (Unicode char indices, not bytes)
- `EditorState` — cursor, selection, style toggle
- `History` + `Command` + `Insert` / `Delete` / `ApplyStyle` — undo/redo (1,000 levels)
- `parse_inline()` — inline markdown parser: `**bold**`, `_italic_`, `__underline__`, `~~strike~~`, `{color:text}`, `[label](url)`

---

## Architecture

Strict Clean Architecture — the dependency rule goes in one direction:

```
infrastructure → application → domain → chaqaq
```

```
crates/chaqaq/     — standalone rich text editor crate (MIT OR Apache-2.0)
  src/
    document.rs    — InlineStyle, InlineText
    rich_text.rs   — RichText + Span
    editor.rs      — EditorState
    commands.rs    — Command, Insert, Delete, ApplyStyle, History
    parser.rs      — parse_inline()

src/
  domain/
    document.rs    — re-exports InlineStyle/InlineText + Block, Document, DocumentMeta
    parser.rs      — re-exports parse_inline
    rich_text.rs   — re-exports RichText, Span
    editor.rs      — re-exports EditorState
    commandes.rs   — re-exports Command, Insert, Delete, ApplyStyle, History
    database.rs    — Notion-like database engine
  application/
    repository.rs          — DocumentRepository trait
    use_cases.rs           — document and block use cases
    database_repository.rs — DatabaseRepository trait
    database_use_cases.rs  — database use cases
    resilience.rs          — retry_with_backoff (SQLite transient errors)
    error.rs               — PinkhaError
  infrastructure/
    migrations.rs            — versioned SQLite migrations
    sqlite_document_store.rs — SqliteDocumentStore (local-first, recommended)
    sqlite_database_store.rs — SqliteDatabaseStore (local-first, recommended)
    json_store.rs            — JsonStore (kept for tests)
  ffi.rs             — UniFFI facade: PinkhaApi exposed to Swift
  pinkha.udl         — UDL interface (Swift ↔ Rust contract)
swift-bindings/      — generated Swift bindings (pinkha.swift, pinkhaFFI.h)
pinkha.xcframework   — compiled XCFramework (iOS device + simulator + macOS)
app/                 — SwiftUI application
  Sources/
    PinkhaApp.swift      — @main
    ContentView.swift    — home screen + PinkhaStore
    DocumentView.swift   — document editor + DocumentViewModel + undo burst
    Models.swift         — Codable Swift mirrors of Rust types
    RichTextEditor.swift — UIViewRepresentable + formatting toolbar pill
    Resilience.swift     — UI-side error handling
```

---

## Features

### Rust Backend

- **Inline parser**: `**bold**`, `_italic_`, `__underline__`, `{color:text}`, `[text](url)` + combinations
- **Recursive blocks**: Text, Heading, Quote, Todo, Divider, Breadcrumb, Database — with nested children
- **Full CRUD**: create, update, delete, reorder, move between parents
- **Lightweight metadata** (`DocumentMeta`) — fast listing without loading blocks, with `updated_at`
- **In-memory rich text editor**: `RichText` + `EditorState` (cursor, selection, style toggle)
- **Undo/redo**: Command pattern, 1,000 levels (`History`)
- **Notion-like database engine**: properties (Title, Text, Number, Selection, Date, Checkbox, URL, Relation, Rollup), views (Table, Kanban, Calendar, Gallery), filters, sorts, groups, rollups computed at read time
- **Search**: title, full-text in blocks (recursive), text values of database entries
- **Local-first SQLite storage**: document-as-JSON + indexed columns for listing, soft delete, `updated_at`, versioned migrations, WAL for concurrency, exponential backoff retry on transient errors
- **Typed errors** (`PinkhaError`): `NotFound`, `InvalidOperation`, `Io`, `Json`, `Db` — no `unwrap()` in production

### SwiftUI UI (iOS 26)

- **Home screen**: list, FAB, dynamic greeting, relative date
- **Editor**: Text / Heading×3 / Quote / Callout / Todo / Divider blocks
- **Rich text**: bold, italic, underline, strikethrough, color palette
- **Keyboard toolbar pill** Notes.app style — Paste / Aa (B/I/U/S) / Highlighter / Undo / Redo / Return / Dismiss
- **Hide-on-menu**: pill elegantly hides when a dropdown menu opens (Notes style)
- **Unified undo/redo**:
  - Glass pill bottom-left (visible when keyboard is closed)
  - Buttons in the keyboard toolbar (visible when keyboard is open)
  - 1,000-level capacity, aligned with Rust backend
  - **Burst undo** Notes style: a burst of keystrokes = 1 step (300ms pause = flush)
  - Covers all ops: add/delete/move/rename block, toggle todo, callout icon, markdown conversion, typing, undo of deletions restores focus
- **Markdown shortcuts**: `# ` → H1, `## ` → H2, `### ` → H3, `> ` → Quote, `!! ` → Callout, `[ ] ` → Todo, `---` → Divider
- **Interactions**: Enter → new block, Return toolbar → line break, Shift+Enter (hardware) → line break, swipe-to-delete, native drag & drop, swipe to dismiss keyboard
- **Performance**: SQLite persist deferred to burst flush (1 write/burst max), span cache per block (skip re-rendering unchanged blocks), undo/redo button state cache

---

## Getting Started

```bash
# Rust backend
cargo run     # demo entry point
cargo test    # all Rust tests (unit + integration + E2E)
cargo test -p chaqaq   # chaqaq crate tests only

# Regenerate Swift bindings after modifying ffi.rs or pinkha.udl
cargo build
cargo run --bin uniffi-bindgen -- generate \
    --library target/debug/libpinkha.dylib \
    --language swift --out-dir swift-bindings/

# Recompile the XCFramework (after modifying Rust code)
./build-xcframework.sh         # release by default

# iOS app (open in Xcode)
open app/Pinkha.xcodeproj

# Full Swift tests (requires a booted simulator)
xcodebuild test -project app/Pinkha.xcodeproj -scheme Pinkha \
    -destination 'id=<UDID>' \
    -only-testing:PinkhaTests -only-testing:PinkhaIntegrationTests

# Publish a new version of chaqaq
# (bump the version in crates/chaqaq/Cargo.toml first)
cd crates/chaqaq && cargo publish
```

---

## Git Workflow

```
feature/** ─┐
fix/**      ├─→ dev ─→ staging ─→ master
chore/**    │
docs/**     │
refactor/** │
perf/**    ─┘
```

3 permanent branches: `master` (prod), `staging` (QA), `dev` (integration). Ephemeral branches are created from `dev` and deleted after merge.

See the "Git workflow" section of [CLAUDE.md](CLAUDE.md) for detailed rules.

---

## CI / Security

- **GitHub Actions**: `cargo test` on push/PR to master/staging/dev (~25s). The Swift job is suspended until Xcode 26 is available on runners.
- **Branch protection**: master/staging/dev → PR required, force-push blocked, deletion blocked, Rust CI required before merge
- **Secret Scanning + Push Protection**: a secret pushed by mistake is detected before reaching the repo
- **Dependabot Alerts + Security Updates**: CVE detection + auto-fix PRs
- **Monthly Dependabot updates** (Cargo + GitHub Actions) grouped to reduce noise

---

## Roadmap

### Done
- [x] Complete inline parser (bold, italic, underline, color, link, combinations)
- [x] Block types, documents, recursive blocks with children
- [x] Rich text editor (`RichText`, `EditorState`, undo/redo)
- [x] Notion-like database engine
- [x] Full CRUD for documents, blocks, databases
- [x] Search (titles, content, database entries)
- [x] Custom errors (`PinkhaError`)
- [x] Local-first SQLite storage (soft delete, `updated_at`, migrations, bundled, WAL, retry)
- [x] UniFFI layer — `PinkhaApi` exposed to Swift
- [x] Swift bindings + XCFramework + Xcode project
- [x] SwiftUI home screen + document editor
- [x] Rich text, toolbar pill, markdown shortcuts
- [x] Full UI undo/redo (1,000 levels, burst typing, toolbar + bottom pill)
- [x] Performance: deferred persist, span cache, undo button cache
- [x] Rust CI, branch protection, Dependabot, Secret Scanning
- [x] Refactor Rust identifiers → English (open source prerequisite)
- [x] **[`chaqaq`](https://crates.io/crates/chaqaq) v0.1.0** — core rich text editor published on crates.io (MIT OR Apache-2.0)

### Still to build
- [ ] Databases UI (Table view, Kanban — backend complete)
- [ ] Search bar (full-text — backend complete)
- [ ] iPad / Mac view (NavigationSplitView)
- [ ] Cross-device sync (CRDT, inspired by y-octo)
- [ ] Re-enable Swift CI (when Xcode 26 available on GitHub runners)

---

## Stack

| Crate / tool | Role |
|---|---|
| [`chaqaq`](https://crates.io/crates/chaqaq) | Rich text editor core (local workspace) |
| `serde` + `serde_json` | JSON serialization / persistence |
| `uuid` | Unique identifiers |
| `chrono` | ISO 8601 timestamps |
| `rusqlite` (bundled) | Embedded SQLite — local-first storage |
| `rusqlite_migration` | Versioned schema migrations |
| `uniffi` | Rust ↔ Swift bridge (auto-generated bindings) |
| `xcodegen` | `.xcodeproj` generation from `project.yml` |
| Swift Testing + XCUITest | Swift unit / integration / E2E tests |

---

## License

- **pinkha**: TBD
- **[chaqaq](https://crates.io/crates/chaqaq)**: MIT OR Apache-2.0
