# pinkha

Application de notes personnelle combinant la fluidité de Craft et la structure de Notion — core en Rust pur.

[![CI](https://github.com/gloiiire/pinkha/actions/workflows/ci.yml/badge.svg)](https://github.com/gloiiire/pinkha/actions/workflows/ci.yml)
[![chaqaq on crates.io](https://img.shields.io/crates/v/chaqaq.svg)](https://crates.io/crates/chaqaq)

> Statut : **backend Rust complet** (208 tests) · **UI SwiftUI fonctionnelle** (rich text, undo/redo, toolbar pill, drag & drop) · **XCFramework compilé** iOS + Mac · **[`chaqaq`](https://crates.io/crates/chaqaq) v0.1.0 publié sur crates.io**

---

## Vision

pinkha est une app de prise de notes avec deux ambitions :

- **Beauté et fluidité** à la Craft : rendu natif, blocs riches, inline styles
- **Structure et puissance** à la Notion : databases, vues, filtres, relations, rollups

Le projet est entièrement écrit en Rust pour le core. Plateformes cibles : iPhone, iPad, Mac.

---

## Workspace

Le repo est un **Cargo workspace** avec deux crates :

| Crate | Description |
|---|---|
| [`chaqaq`](https://crates.io/crates/chaqaq) | Core rich text editor — publié sur crates.io (MIT OR Apache-2.0) |
| `pinkha` | Application complète — dépend de `chaqaq` |

### chaqaq — crate open source

`chaqaq` est le moteur d'édition inline extrait de pinkha, utilisable indépendamment dans n'importe quel projet Rust :

```toml
[dependencies]
chaqaq = "0.1"
```

Il fournit :
- `InlineStyle` / `InlineText` — modèle de texte riche sérialisable
- `RichText` + `Span` — représentation d'édition (indices chars Unicode, pas bytes)
- `EditorState` — curseur, sélection, toggle de style
- `History` + `Command` + `Insert` / `Delete` / `ApplyStyle` — undo/redo (1 000 niveaux)
- `parse_inline()` — parser markdown inline : `**bold**`, `_italic_`, `__underline__`, `~~strike~~`, `{color:text}`, `[label](url)`

---

## Architecture

Clean Architecture stricte — la règle de dépendance va dans un seul sens :

```
infrastructure → application → domain → chaqaq
```

```
crates/chaqaq/     — crate autonome rich text editor (MIT OR Apache-2.0)
  src/
    document.rs    — InlineStyle, InlineText
    rich_text.rs   — RichText + Span
    editor.rs      — EditorState
    commands.rs    — Command, Insert, Delete, ApplyStyle, History
    parser.rs      — parse_inline()

src/
  domain/
    document.rs    — re-exporte InlineStyle/InlineText + Block, Document, DocumentMeta
    parser.rs      — re-exporte parse_inline
    rich_text.rs   — re-exporte RichText, Span
    editor.rs      — re-exporte EditorState
    commandes.rs   — re-exporte Command, Insert, Delete, ApplyStyle, History
    database.rs    — moteur database type Notion
  application/
    repository.rs          — trait DocumentRepository
    use_cases.rs           — use cases documents et blocs
    database_repository.rs — trait DatabaseRepository
    database_use_cases.rs  — use cases database
    resilience.rs          — retry_with_backoff (SQLite transient errors)
    error.rs               — PinkhaError
  infrastructure/
    migrations.rs            — migrations SQLite versionnées
    sqlite_document_store.rs — SqliteDocumentStore (local-first, recommandé)
    sqlite_database_store.rs — SqliteDatabaseStore (local-first, recommandé)
    json_store.rs            — JsonStore (conservé pour les tests)
  ffi.rs             — façade UniFFI : PinkhaApi exposée à Swift
  pinkha.udl         — interface UDL (contrat Swift ↔ Rust)
swift-bindings/      — bindings Swift générés (pinkha.swift, pinkhaFFI.h)
pinkha.xcframework   — XCFramework compilé (iOS device + simulator + macOS)
app/                 — application SwiftUI
  Sources/
    PinkhaApp.swift      — @main
    ContentView.swift    — écran d'accueil + PinkhaStore
    DocumentView.swift   — éditeur de document + DocumentViewModel + undo burst
    Models.swift         — miroirs Swift Codable des types Rust
    RichTextEditor.swift — UIViewRepresentable + toolbar pill de formatage
    Resilience.swift     — gestion d'erreurs côté UI
```

---

## Fonctionnalités

### Backend Rust

- **Parser inline** : `**gras**`, `_italique_`, `__souligné__`, `{couleur:texte}`, `[texte](url)` + combinaisons
- **Blocs récursifs** : Text, Heading, Quote, Todo, Divider, Breadcrumb, Database — avec enfants imbriqués
- **CRUD complet** : créer, modifier, supprimer, réordonner, déplacer entre parents
- **Métadonnées légères** (`DocumentMeta`) — listing rapide sans charger les blocs, avec `updated_at`
- **Rich text editor in-memory** : `RichText` + `EditorState` (curseur, sélection, toggle de style)
- **Undo/redo** : pattern Command, capacité 1000 (`History`)
- **Database type Notion** : propriétés (Title, Text, Number, Selection, Date, Checkbox, URL, Relation, Rollup), vues (Table, Kanban, Calendar, Gallery), filtres, tris, groupes, rollups calculés à la lecture
- **Recherche** : titre, full-text dans les blocs (récursif), valeurs textuelles des entrées de database
- **Stockage local-first SQLite** : document-as-JSON + colonnes indexées pour le listing, soft delete, `updated_at`, migrations versionnées, WAL pour la concurrence, retry exponential backoff sur erreurs transitoires
- **Erreurs typées** (`PinkhaError`) : `NotFound`, `InvalidOperation`, `Io`, `Json`, `Db` — jamais de `unwrap()` en production

### UI SwiftUI (iOS 26)

- **Écran d'accueil** : liste, FAB, salutation dynamique, date relative
- **Éditeur** : blocs Text / Heading×3 / Quote / Callout / Todo / Divider
- **Texte riche** : gras, italique, souligné, barré, palette de couleurs
- **Toolbar pill clavier** style Notes.app — Coller / Aa (B/I/U/S) / Highlighter / Undo / Redo / Return / Dismiss
- **Hide-on-menu** : la pill s'efface élégamment quand un menu déroulant s'ouvre (style Notes)
- **Undo/redo unifié** :
  - Pill glass en bas-gauche (visible clavier fermé)
  - Boutons dans la toolbar clavier (visible clavier ouvert)
  - Capacité 1000 niveaux, alignée sur le back Rust
  - **Burst undo** style Notes : une rafale de frappe = 1 étape (pause 300 ms = flush)
  - Couvre toutes les ops : add/delete/move/rename block, toggle todo, icon callout, conversion markdown, frappe, undo des suppressions ramène le focus
- **Raccourcis markdown** : `# ` → H1, `## ` → H2, `### ` → H3, `> ` → Quote, `!! ` → Callout, `[ ] ` → Todo, `---` → Divider
- **Interactions** : Enter → nouveau bloc, Return toolbar → saut de ligne, Shift+Enter (hardware) → saut de ligne, swipe-to-delete, drag & drop natif, dismiss clavier par swipe
- **Performance** : persist SQLite différé au flush burst (1 write/burst max), cache des spans déjà sync (skip rendu des blocs non-modifiés), cache d'état des boutons undo/redo

---

## Lancer le projet

```bash
# Backend Rust
cargo run     # point d'entrée démo
cargo test    # tous les tests Rust (unitaires + intégration + E2E)
cargo test -p chaqaq   # tests du crate chaqaq uniquement

# Régénérer les bindings Swift après modification de ffi.rs ou pinkha.udl
cargo build
cargo run --bin uniffi-bindgen -- generate \
    --library target/debug/libpinkha.dylib \
    --language swift --out-dir swift-bindings/

# Recompiler le XCFramework (après modification du code Rust)
./build-xcframework.sh         # release par défaut

# App iOS (ouvrir dans Xcode)
open app/Pinkha.xcodeproj

# Tests Swift complets (nécessite simulateur booté)
xcodebuild test -project app/Pinkha.xcodeproj -scheme Pinkha \
    -destination 'id=<UDID>' \
    -only-testing:PinkhaTests -only-testing:PinkhaIntegrationTests

# Publier une nouvelle version de chaqaq
# (bumper la version dans crates/chaqaq/Cargo.toml d'abord)
cd crates/chaqaq && cargo publish
```

---

## Workflow git

```
feature/** ─┐
fix/**      ├─→ dev ─→ staging ─→ master
chore/**    │
docs/**     │
refactor/** │
perf/**    ─┘
```

3 branches permanentes : `master` (prod), `staging` (QA), `dev` (intégration). Les branches éphémères sont créées depuis `dev` et supprimées après merge.

Cf. la section "Git workflow" de [CLAUDE.md](CLAUDE.md) pour le détail des règles.

---

## CI / Sécurité

- **GitHub Actions** : `cargo test` sur push/PR vers master/staging/dev (~25 s). Le job Swift est suspendu en attendant Xcode 26 sur les runners.
- **Branch protection** : master/staging/dev → PR obligatoire, force-push bloqué, suppression bloquée, CI Rust requise avant merge
- **Secret Scanning + Push Protection** : un secret pushé par erreur est détecté avant qu'il atteigne le repo
- **Dependabot Alerts + Security Updates** : CVE détectées + auto-PR de fix
- **Dependabot updates mensuels** (Cargo + GitHub Actions) groupés pour éviter le bruit

---

## Roadmap

### Fait
- [x] Parser inline complet (bold, italic, underline, color, link, combinaisons)
- [x] Types de blocs, documents, blocs récursifs avec enfants
- [x] Rich text editor (`RichText`, `EditorState`, undo/redo)
- [x] Moteur database type Notion
- [x] CRUD complet documents, blocs, databases
- [x] Recherche (titres, contenu, entrées database)
- [x] Erreurs custom (`PinkhaError`)
- [x] Stockage SQLite local-first (soft delete, `updated_at`, migrations, bundled, WAL, retry)
- [x] Couche FFI UniFFI — `PinkhaApi` exposée à Swift
- [x] Bindings Swift + XCFramework + projet Xcode
- [x] Écran d'accueil SwiftUI + éditeur de document
- [x] Texte riche, toolbar pill, raccourcis markdown
- [x] Undo/redo complet UI (1000 niveaux, burst typing, toolbar + pill bas)
- [x] Performance : persist différé, cache spans, cache boutons undo
- [x] CI Rust, branch protection, Dependabot, Secret Scanning
- [x] Refactor identifiants Rust → anglais (prérequis open source)
- [x] **[`chaqaq`](https://crates.io/crates/chaqaq) v0.1.0** — core rich text editor publié sur crates.io (MIT OR Apache-2.0)

### Reste à construire
- [ ] UI Databases (vue Tableau, Kanban — backend complet)
- [ ] Barre de recherche (full-text — backend complet)
- [ ] Vue iPad / Mac (NavigationSplitView)
- [ ] Sync entre appareils (CRDT, s'inspirer de y-octo)
- [ ] Réactiver Swift CI (quand Xcode 26 dispo sur runners GitHub)

---

## Stack

| Crate / outil | Rôle |
|---|---|
| [`chaqaq`](https://crates.io/crates/chaqaq) | Rich text editor core (workspace local) |
| `serde` + `serde_json` | Sérialisation / persistance JSON |
| `uuid` | Identifiants uniques |
| `chrono` | Timestamps ISO 8601 |
| `rusqlite` (bundled) | SQLite embarqué — stockage local-first |
| `rusqlite_migration` | Migrations de schéma versionnées |
| `uniffi` | Bridge Rust ↔ Swift (bindings générés automatiquement) |
| `xcodegen` | Génération du `.xcodeproj` depuis `project.yml` |
| Swift Testing + XCUITest | Tests Swift unit / integration / E2E |

---

## Licence

- **pinkha** : à définir
- **[chaqaq](https://crates.io/crates/chaqaq)** : MIT OR Apache-2.0
