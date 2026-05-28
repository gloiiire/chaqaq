# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Vision

**chaqaq** — app de notes personnelle, mélange Craft (beauté, fluidité, rendu natif) + Notion (databases, structure). Full Rust pour le core. Objectif : publication open source, car un rich text editor en Rust n'existe pas encore dans l'écosystème.

Plateformes cibles : iPhone, iPad, Mac, Web, Android. Décision UI pas encore prise — Flutter + `flutter_rust_bridge` est l'option principale (rendu GPU natif, Rust pour le core). Le projet est actuellement en phase core Rust pur.

## Commands

```bash
cargo run     # alias: r
cargo build   # alias: cb
cargo check   # alias: cc
cargo test
```

## Architecture (Clean Architecture)

```
src/
  domain/          — types purs + parser (aucune dépendance externe)
  application/     — trait DocumentRepository + use cases
  infrastructure/  — JsonStore implémente DocumentRepository
  main.rs          — point d'entrée démo
```

Règle de dépendance : `infrastructure` → `application` → `domain`. Le domaine ne sait rien du stockage — ajouter SQLite ou CloudStore sans toucher au domaine.

### `domain/document.rs`
- `InlineStyle`: Bold, Italic, Underline, Color(String), Link(String)
- `InlineText { content: String, styles: Vec<InlineStyle> }` — feuille de tout texte riche
- `BlockContent`: Text, Heading { level }, Quote { icon }, Todo { done }, Divider, Breadcrumb, Database
- `Block { id: Uuid, content: BlockContent, children: Vec<Block> }` — nœud récursif
- `Document { id, cover, title: Vec<InlineText>, blocks: Vec<Block> }`

### `domain/parser.rs`
State machine sur `chars().peekable()`. Deux booléens `bold`/`italic` (combinables) + `Option<LinkState>` pour les liens. `flush()` vide `current_text` dans le résultat avec les styles actifs.
- `**gras**` → Bold
- `_italique_` → Italic
- `**_combiné_**` → Bold + Italic simultanés
- `[texte](url)` → Link(url)
- `Underline` (`__texte__`) et `Color` (`{red:texte}`) — syntaxe à inventer, pas encore implémentés

### `application/repository.rs`
Trait `DocumentRepository` : `save`, `load`, `list`.

### `application/use_cases.rs`
`creer_document`, `obtenir_document`, `lister_documents`, `ajouter_bloc` — prennent tous un `&dyn DocumentRepository`.

### `infrastructure/json_store.rs`
`JsonStore { dir: PathBuf }` implémente `DocumentRepository`. Documents stockés en `{uuid}.json`.

## Roadmap

Ce qui reste à construire dans l'ordre logique :
1. Syntaxe Underline (`__texte__`) et Color (`{red:texte}`) dans le parser
2. `list_documents()` avec métadonnées légères (sans charger tout le contenu)
3. Gestion d'erreurs custom — types d'erreurs propres au lieu de `Box<dyn Error>`
4. Rich text editor — curseur, sélection, undo/redo, styles inline — contribution principale à l'écosystème Rust
5. Décision finale UI (Flutter + flutter_rust_bridge vs Slint vs autre)
6. Sync entre appareils (CRDT — s'inspirer de y-octo)

Ce qui n'existe pas encore en Rust et qu'on va construire :
- Un rich text editor en Rust
- Un système de blocks imbriqués avec drag & drop
- Un moteur de database type Notion

## Code style
- Commentaires en français
- Pas de `unwrap()` — toujours `?` et `Result`
- Nommage idiomatique Rust (snake_case, PascalCase)
- `flush()` pattern pour les parsers

## Notes
- `#![allow(dead_code)]` intentionnel tant que l'API se construit.
- JSON sur disque utilise `style` (ancien) alors que la struct utilise `styles` — `#[serde(rename)]` nécessaire pour charger les anciens fichiers.
