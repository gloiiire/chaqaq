# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Vision

**pinkha** — app de notes personnelle, mélange Craft (beauté, fluidité, rendu natif) + Notion (structure, databases). Full Rust pour le core. Objectif : publication open source, car un rich text editor en Rust n'existe pas encore dans l'écosystème.

Plateformes cibles : iPhone, iPad, Mac. Décision UI : **SwiftUI + UniFFI** — rendu 100 % natif (iOS 26, scroll physics natif, tab bar native), Rust pour le core.

## Vocabulaire métier

Pinkha utilise un vocabulaire orienté "bibliothèque physique" plutôt que les termes génériques de Notion/Apple Notes. Mapping complet + grammaire d'actions + i18n EN/FR : **`utilities/docs/VOCABULARY.md`**.

| Concept | Nom (code + UX) | Pair sémantique |
| --- | --- | --- |
| Document riche text | **Leaf** | feuille d'un livre |
| Database / collection | **Book** | recueil relié de feuilles |
| Row d'un Book | **bound Leaf** | feuille reliée |
| Document standalone | **loose Leaf** | feuille volante |
| Folder | **Shelf** | étagère qui contient livres + feuilles |
| Workspace (la home tab) | **Library** | la bibliothèque |
| Trash | **Compost** | feuilles tombées en compost |

Grammaire : **take** a leaf, **open** a book, **build** a shelf, **bind** a leaf to a book, **unbind**, **shelve**, **discard to compost**.

Termes externes préservés (ne pas renommer dans le code) : `NotionDatabase*`, `notion_database`, `child_database`, `ChildDatabase*` (terminologie API Notion), `DocumentDataModel` (type Realm/Craft externe), `db_path` (chemin fichier SQLite — pas un Pinkha Book), `documentation`/`documented`/`documenting` (anglais courant).

## Commands

```bash
cargo run     # alias: r
cargo build   # alias: cb
cargo check   # alias: cc
cargo test

# Tester uniquement le crate chaqaq
cargo test -p chaqaq

# Régénérer les bindings Swift après modification du .udl ou de ffi.rs.
# pinkha.swift va dans le SwiftPM package, les headers C (pinkhaFFI.h /
# .modulemap) restent dans swift-bindings/ pour build-xcframework.sh.
cargo build
cargo run --bin uniffi-bindgen -- generate --library target/debug/libpinkha.dylib \
    --language swift --out-dir swift-bindings/
mv swift-bindings/pinkha.swift app/Packages/PinkhaFFI/Sources/PinkhaFFI/

# Publier une nouvelle version de chaqaq sur crates.io
# (bumper la version dans crates/chaqaq/Cargo.toml d'abord)
cd crates/chaqaq && cargo publish
```

## Architecture (Clean Architecture côté Rust + multi-target SwiftPM côté Swift)

Le repo est un **Cargo workspace** avec trois crates Rust + une application Swift modulaire en 6 packages SwiftPM (10 targets).

### Vue d'ensemble

```
pinkha/
├── crates/                  Cargo workspace
│   ├── chaqaq/              Rich text editor autonome (crates.io: chaqaq v0.1.0, MIT OR Apache-2.0)
│   ├── realm-codec/         Parser/writer Realm v9 binary (crates.io: realm-codec v0.1.0)
│   └── pinkha-mcp/          MCP server pour Claude (tooling interne)
├── src/                     Le core Rust pinkha (dépend de chaqaq via path)
├── pinkha.xcframework/      XCFramework généré par ./build-xcframework.sh (gitignoré)
├── swift-bindings/          Headers C (.h + .modulemap) consommés par le xcframework
└── app/                     Application iOS SwiftUI
    ├── project.yml          Config xcodegen
    ├── Pinkha.xcodeproj/    Généré
    ├── Packages/            6 packages SwiftPM (10 targets) (cf. section dédiée)
    └── Sources/
        ├── App/             Composition root uniquement (PinkhaApp, ContentView, AppDelegate, SplashView, Composer+QuickActions)
        ├── Assets.xcassets
        ├── Info.plist
        └── Localizable.xcstrings
```

### Rust — `src/`

```
src/
  domain/                   types purs, aucune dép externe (sauf chaqaq)
    leaf.rs                 re-exporte InlineStyle/InlineText depuis chaqaq + Block, Leaf, LeafMeta
    book/                   moteur type Notion (Property, Entry, View, Filter, Sort, Rollup)
    shelf.rs                Shelf + ShelfMeta
    parser.rs / rich_text.rs / editor.rs / commands.rs   re-exports chaqaq
  application/              traits + use cases (dépend seulement de domain)
    repository.rs           trait LeafRepository
    book_repository.rs      trait BookRepository
    shelf_repository.rs     trait ShelfRepository
    book_use_cases/         CRUD + query + properties + views + search/rollup
    shelf_use_cases.rs
    use_cases/
      leaf.rs               CRUD leaves + blocs
      blocks.rs             ajouter/modifier/supprimer/réordonner/imbriquer/déplacer
      search.rs             super_search dédupliquée côté Rust
      trash.rs              empty_trash bulk
      book_leaf_sync.rs     orchestration cross-domain (Leaf + Book) — update_entry_propagating_title, delete_book_cascade, set_published_at_source…
    resilience.rs           retry_with_backoff (exponentiel, 3 essais, transient-only)
    error.rs                PinkhaError (NotFound / InvalidOperation / Io / Json / Db)
  infrastructure/           stockage (dépend de application)
    migrations.rs                  migrations SQLite versionnées + rename_legacy_schema (documents→leaves, databases→books, folders→shelves, folder_id→shelf_id, parent_doc_id→parent_leaf_id) idempotent
    sqlite_leaf_store.rs           SqliteLeafStore : local-first
    sqlite_book_store.rs           SqliteBookStore
    sqlite_shelf_store.rs          SqliteShelfStore
    leaf_store.rs / book_store.rs  JsonStore : tests legacy
  extractors/               imports (Notion / Bear / Craft)
    notion/                 reqwest rustls-tls, API v1 paginée, 2-pass mention rewriting
    bear/                   rusqlite read-only + parseur Markdown Bear
    craft_textbundle/, craft_combined/  realm-codec read-only
  ffi/                      façade UniFFI éclatée par domaine (composition root)
    mod.rs                  struct PinkhaApi (stores + uow()), re-exports
    error.rs                PinkhaError FFI + From<CoreError>
    types.rs                dictionnaires FFI (LeafMetaFfi, BookMetaFfi, ShelfMetaFfi, SuperSearchResultsFfi…) + converters
    validation.rs           parse_uuid, parse_json (5 Mo max), check_string (64 Ko max)
    leaves.rs / books.rs / shelves.rs / library.rs / extractors.rs   impl PinkhaApi par domaine
  pinkha.udl                interface UDL déclarant l'API publique Swift/Kotlin
  bin/uniffi-bindgen.rs     binaire local pour générer les bindings
  main.rs                   point d'entrée démo
```

Règle de dépendance : `infrastructure` → `application` → `domain`. Le domaine ne sait rien du stockage.

### Swift — `app/Packages/` (6 packages SwiftPM (10 targets))

L'application iOS est éclatée en **6 packages SwiftPM (10 targets)** avec un DAG enforced par le compilateur. Le target Xcode `Pinkha` ne contient plus que la composition root (`App/`) + les ressources.

#### Packages plateforme (5)

```
PinkhaFFI                   wrappe pinkha.xcframework (binaryTarget) + miroirs Codable des types Rust
  ├─ pinkha.swift           bindings générés par uniffi-bindgen
  ├─ {Leaf,Book,Entry,Property,PropertyValue,View,BlockContent}.swift  miroirs Codable
  └─ PinkhaApi+Typed.swift  extensions typées qui décodent automatiquement les FFI JSON-string

PinkhaCore                  utilitaires cross-cutting (dépend PinkhaFFI)
  ├─ AppSettings.swift              @Observable @MainActor (accent, appearance, recentCount, hapticsEnabled, theme, rotationLock)
  ├─ PinkhaStore.swift              @Observable @MainActor — owner du PinkhaApi + ListItems + recents
  ├─ WorkspaceItem.swift            enum Leaf | Book (nom conservé pour éviter le conflit SwiftUI.LibraryItem)
  ├─ SettingsView.swift             sheet préférences app-wide
  ├─ Resilience.swift               tryCatch(into:), errorAlert, PinkhaError userMessage/isRecoverable
  ├─ Keychain.swift                 wrapper kSecAttrAccessibleWhenUnlockedThisDeviceOnly (tokens Notion)
  ├─ Observability.swift            wrapper Sentry (start/capture/captureAsEvent)
  ├─ Haptic.swift                   Haptic.tap/toggle/soft/success/warning + HapticTapStyle PrimitiveButtonStyle
  ├─ CoversDirectory.swift          CoverImageStorage (FS helpers pour images de cover)
  ├─ ISO8601DateFormatter+FullRfc.swift   formatter RFC 3339 partagé (round-trip Rust ↔ Swift)
  └─ UIKit/                         bridges UIKit : SafariSwitcher, UIKitContextMenu, TabSnapshotCache, GlobalKeyboardDismissPan

PinkhaDesignSystem          composants UI réutilisables (dépend PinkhaCore + PinkhaFFI)
  ├─ SectionHeader.swift            label uppercase semibold avec kerning
  ├─ CoverImageView.swift           rendu cover (gradient / file / URL / placeholder)
  ├─ LockToolbarButton.swift        toolbar lock partagé Leaf + Book
  ├─ SystemAlertCard.swift          alert glass clone iOS 26 + .systemAlertOverlay(isPresented:card:)
  └─ PropertyInputRow.swift         row d'édition d'une PropertyValueFfi pour les sheets

PinkhaRichText              éditeur chaqaq-backed (dépend PinkhaCore + DesignSystem + FFI)
  ├─ RichTextEditor.swift                       UIViewRepresentable (33+ closures dans son init public)
  ├─ RichTextEditorCoordinator.swift           UITextViewDelegate + UIGestureRecognizerDelegate
  ├─ RichTextEditorCoordinator+{Menus,Selection,Style,Toolbar}.swift
  ├─ ExpandingTextView.swift                    UITextView custom (hauteur auto, hooks raccourcis)
  ├─ MentionBar.swift                           picker @-mention au-dessus du clavier
  ├─ RichTextAttributes.swift                   NSAttributedString.Key.pinkhaColor
  ├─ RichTextConversion.swift                   spansToAttributed / attributedToSpans
  └─ MarkdownShortcuts.swift                    markdownShortcut(for:) — H1/H2/H3/Quote/Callout/Todo/Divider

PinkhaComposer              orchestrator composition (dépend PinkhaCore + FFI)
  ├─ Composer.swift                  @Observable @MainActor (sheets, createMode, CreationContext, Notification.Name, TabKind, PendingChildPage)
  └─ StandaloneStyle.swift           type partagé Leaf/Library (cover, icon, theme, publishedAt, customCoverData)
```

#### Package features (PinkhaFeatures, 5 targets)

```
PinkhaFeatures              5 cibles avec DAG : LeafFeature ← BookFeature ← {LibraryFeature, SearchFeature, ImportFeature}
  ├─ LeafFeature            éditeur de leaf
  │   ├─ Editor/LeafView, LeafViewModel (+ Persistence/Blocks/TitleCover/Undo), LeafView+Toolbar, LeafView+BlockCallbacks, LeafTitle, LeafDecor, LeafViewHelpers, EditableBlock, ActionRepeater, EmojiPicker, ExpandingBlockFAB
  │   ├─ Blocks/BlockRows, BlockRowsExtra, EmbedRowView, EmbedMetadata
  │   ├─ Sheets/BindLeafToBookSheet, LeafPublishDateSheet
  │   └─ TabManager.swift   cache MRU des LeafViewModel ouverts (Safari-style tab switcher)
  │
  ├─ BookFeature            ← LeafFeature (NavigationLink → LeafView)
  │   ├─ BookView, BookViewModel, BookHeader, BookToolbar, BookCascadeDialogs, BooksHomeView
  │   ├─ Sheets/BookFilterSheet, BookPropertiesSheet
  │   └─ Views/{Board,Calendar,Gallery,List,Table}View + BookGroupHeader
  │
  ├─ LibraryFeature         ← LeafFeature + BookFeature
  │   ├─ LibraryView, LibraryView+Sort, LibraryRow, LibraryEmptyState
  │   ├─ RecentStrip, AllLeavesSwitcher
  │   ├─ ShelfView, ShelvesSectionView, ShelfRow
  │   ├─ CompostView (anciennement TrashView, struct gardée TrashView pour l'instant)
  │   ├─ InboxView, CreateBubble, CreateLeafSheet
  │   └─ PinkhaStore+Composer.swift   overloads createNote(in:Composer.CreationContext, style:StandaloneStyle), createNoteInBook, applyStandaloneStyle
  │
  ├─ ImportFeature          ← (indépendant — aucune dep feature)
  │   ├─ NotionImportView, NotionOAuth2
  │   ├─ BearImportView
  │   └─ CraftTextBundleImportView, CraftCombinedImportView
  │
  └─ SearchFeature          ← LeafFeature + BookFeature + LibraryFeature
      └─ SearchView         hits leaves + books + shelves, NavigationLink direct vers Leaf/Book/Shelf
```

### `app/Sources/` — app target

```
app/Sources/
├── App/
│   ├── PinkhaApp.swift              @main — bootstrap @Observable Composer/AppSettings/TabManager/PinkhaStore
│   ├── AppDelegate.swift            @UIApplicationDelegateAdaptor, drainage Quick Actions
│   ├── ContentView.swift            TabView 4 onglets : Library | Books | Inbox | Search ; orchestre les sheets et alertes globales
│   ├── SplashView.swift             écran d'ouverture (fade-in du logo)
│   └── Composer+QuickActions.swift  extension qui lit AppDelegate.pendingShortcutType (app-side car AppDelegate ne peut pas vivre en package)
├── Assets.xcassets
├── Info.plist + InfoPlist.xcstrings
└── Localizable.xcstrings
```

Règle : un fichier qui doit lire/écrire `AppDelegate.pendingShortcutType` ou observer le scene lifecycle reste **forcément** dans `app/Sources/App/` — sinon il appartient à un package.

### `crates/chaqaq` — crate autonome (publié sur crates.io)

Toute la logique d'édition inline vit ici. Seule dépendance : `serde`.

- **`InlineStyle`** : Bold, Italic, Underline, Strikethrough, Color(String), Link(String)
- **`InlineText { content, styles }`** — fragment sérialisable de texte riche
- **`RichText`** : string plate de chars + `Vec<Span>`. Indices char Unicode (pas bytes). `insert_char` / `delete_char` / `toggle_style` / `restore_spans`. Conversion `From<&Vec<InlineText>>` ↔ `From<&RichText> for Vec<InlineText>` sans perte.
- **`EditorState { text, cursor, selection }`** : `insert`, `delete_before/after`, `move_left/right`, `go_to_start/end`, `select(range)`, `toggle_style(style)`
- **`Command` trait** + `Insert`, `Delete`, `ApplyStyle` — chacun implémente `execute` / `undo`
- **`History`** : pile undo/redo, capacité configurable (défaut 1 000), `apply` / `undo` / `redo` / `can_undo` / `can_redo`
- **`parse_inline(input)`** : state machine sur `chars().peekable()`. `**bold**`, `_italic_`, `__underline__`, `~~strike~~`, `{color:text}`, `[label](url)`, combinaisons.

> **Note langue** : tous les commentaires et doc-comments sont en **anglais** — dans `crates/chaqaq` comme dans `pinkha`.

> **Publication** : bumper la version dans `crates/chaqaq/Cargo.toml` (semver), puis `cd crates/chaqaq && cargo publish`. Une version publiée est immuable. pinkha référence chaqaq via `{ path = "crates/chaqaq" }` donc compile toujours en local sans publier.

### `domain/leaf.rs`
Re-exporte `InlineStyle` et `InlineText` depuis chaqaq. Définit les types pinkha-spécifiques :
- `BlockContent` — **12 variants** : Text, Heading { level, text }, Quote { icon, text }, Divider, Todo { done, text }, Breadcrumb, Book { id }, BulletedListItem, NumberedListItem, Code, Leaf { id }, Embed
- `Block { id: Uuid, content: BlockContent, children: Vec<Block>, color, background_color, text_direction }` — nœud récursif
- `Leaf { id, cover, icon, title: Vec<InlineText>, blocks: Vec<Block>, shelf_id, parent_leaf_id, locked, created_at, accent_color, text_direction, theme, published_at, pinned_at, manual_order }` — **15 champs**
- `LeafMeta { id, cover, icon, title, updated_at, created_at, published_at, shelf_id, parent_leaf_id, pinned_at, manual_order }` — vue légère sans blocks pour `list()`, construite **depuis les colonnes SQLite** (pas depuis le blob JSON)

> ⚠️ **Root-ness a deux orthographes, et elles doivent rester d'accord.** Une leaf est « à la racine » quand elle n'a pas de parent *et* pas d'étagère **active**. `ShelfRepository::delete` est volontairement non destructif (il laisse `leaf.shelf_id` intact pour que `restore` ramène le sous-arbre), donc tester `shelf_id.is_none()` classe les leaves d'une étagère compostée sous un conteneur invisible — elles disparaissent de la Library sans avoir été supprimées. Le prédicat SQL de `list_by_shelf(None)` fait autorité ; `list_root_leaves` s'appuie dessus. Un test (`the_two_root_listings_agree`) verrouille l'équivalence. Ce bug a shippé une fois.

> ⚠️ Les champs dénormalisés (`shelf_id`, `parent_leaf_id`, `icon`, `pinned_at`, `manual_order`, `published_at`, `cover`, `title`) existent **à la fois** dans la colonne SQLite indexée et dans le blob JSON `data`. Tout mutateur qui n'écrit que la colonne sera écrasé au prochain `save()` (qui sérialise depuis le blob). Utiliser `json_set(data, '$.champ', …)` dans le même `UPDATE` — cf. `move_to_shelf`, `set_pinned`, `set_manual_order`. Cette classe de bug a déjà shippé deux fois.

### `domain/parser.rs` / `rich_text.rs` / `editor.rs` / `commands.rs`
Simples re-exports depuis `chaqaq` — aucune logique propre.

### `domain/book.rs`
Moteur type Notion (défini dans pinkha, pas dans chaqaq) :
- `PropertyType` : Title, Text, Number, Selection, SelectionMultiple, Date, Checkbox, Url, Relation, Rollup
- `PropertyValue` : valeurs correspondantes + `Empty`
- `Entry { id, created_at: String (ISO 8601), values: HashMap<Uuid, PropertyValue> }`
- `ViewType` : Table, Kanban { group_by }, Calendar { property_id }, Gallery
- `Filter { property_id, condition: FilterCondition }`, `Sort { property_id, order, source: SortSource }`
- `SortSource` : Property | Creation | ManualThenCreation (pour journaux mixtes)
- `Book { id, title, properties, entries, views }`, `BookMeta { id, title, updated_at }`

### `application/error.rs`
`PinkhaError` : `NotFound(Uuid)`, `InvalidOperation(String)`, `Io(std::io::Error)`, `Json(serde_json::Error)`, `Db(String)`
— `Db(String)` convertit les erreurs rusqlite en string pour ne pas coupler l'application à SQLite.
— implémente `std::error::Error` + `From<io::Error>` + `From<serde_json::Error>`

### `application/use_cases.rs`
- `create_leaf`, `get_leaf`, `list_leaves`, `delete_leaf`
- `update_leaf_title`, `update_leaf_cover`
- `add_block`, `update_block`, `delete_block`
- `reorder_blocks(leaf_id, order)` — réordonne les blocs racine
- `reorder_child_blocks(leaf_id, parent_id, order)` — réordonne les enfants d'un bloc
- `add_child_block(leaf_id, parent_id, content)` — imbrique un bloc
- `move_block(leaf_id, block_id, new_parent_id: Option<Uuid>)` — déplace vers un parent (None = racine)
- `save_edited_block(leaf_id, block_id, &EditorState)` — bridge éditeur → persistance
- `search_leaves(query)` — insensible à la casse dans les titres
- `search_in_blocks(query)` — plein texte dans le contenu des blocs (récursif)

### `application/book_use_cases.rs`
- `create_book`, `get_book`, `list_books`, `delete_book`
- `add_entry`, `update_entry`, `delete_entry`
- `add_property`, `rename_property`, `delete_property` (nettoie les valeurs dans les entrées)
- `add_view`, `update_view(view_id, filters, sorts)`, `delete_view` (bloque sur la dernière)
- `query(book_id, view_id)` — filtres + tris
- `query_with_rollups` — requête + rollups calculés à la lecture
- `column_aggregate(book_id, prop_id, aggregate)`
- `grouped_query(book_id, view_id, group_by)`
- `search_entries(book_id, query)` — insensible à la casse dans toutes les valeurs textuelles
- `evaluate_rollups(db, entries)` — calcul des colonnes Rollup (non persisté)

### Use cases Rust-first (la donnée ne se traite jamais en Swift)
- `library_snapshot()` — root leaves + all leaves + books + shelves en **un** crossing (`ffi/library.rs`). Remplace les 4 appels de `PinkhaStore.load()`, qui tourne après chaque mutation depuis ~20 sites. Au-delà du coût : 4 lectures séparées peuvent observer 4 états différents de la base si une écriture s'intercale. Root-ness délègue à `list_root_leaves` — surtout ne pas en écrire une 2ᵉ définition.
- `super_search(query)` — toutes les surfaces de recherche en un appel, dédup titre/contenu côté Rust (`use_cases/search.rs`)
- `empty_trash()` — purge bulk docs + books + shelves (`use_cases/trash.rs`)
- `delete_items` / `restore_items` / `purge_items(leaf_ids, book_ids, shelf_ids)` — sélection mixte en **un** appel, retourne `BulkOutcomeFfi { affected, skipped }` (`use_cases/trash.rs`). Les ids déjà disparus sont `skipped`, pas une erreur : une sélection est un snapshot pris avant la confirmation, elle peut légitimement périmer. Remplace les boucles Swift qui payaient 1 crossing FFI + 1 `load()` complet **par item**.
- `list_child_shelves(parent_id)` — filtrage parent/enfant côté Rust (`shelf_use_cases.rs`)
- `create_leaf_in_book(book_id, title, values)` — crée le doc, remplit la colonne `PAGE_LINK_PROPERTY` (`__pinkha_page__`) et la colonne Title, lie l'entry au doc (`book_leaf_sync.rs`)
- `get_leaf_meta(id)` — méta légère sans l'arbre de blocs (icône/cover/titre)

### `infrastructure/migrations.rs`
Migrations **écrites à la main** (le crate `rusqlite_migration` est déclaré dans Cargo.toml mais jamais importé). `apply_leaf_migrations` / `apply_book_migrations` délèguent toutes deux à `apply_migrations`, qui s'exécute en entier à chaque ouverture de store — donc 3× par démarrage à froid. Chaque évolution = un `add_column_if_missing` / `CREATE INDEX IF NOT EXISTS` de plus, suivi d'un bump de `PRAGMA user_version` (16 aujourd'hui). Tout doit donc rester idempotent.

### `infrastructure/sqlite_leaf_store.rs` + `sqlite_book_store.rs`
Stockage SQLite local-first. Schéma : leaf-as-JSON dans une colonne `data`, avec colonnes indexées (`title_text`, `title_json`, `cover`) pour `list()` rapide sans désérialiser les blocs.
- `updated_at` géré automatiquement à chaque `save()` — prêt pour sync future
- Soft delete : `delete()` pose `deleted_at` au lieu de supprimer — données récupérables pour CRDT
- SQLite bundlé (`features = ["bundled"]`) — pas de dépendance système, fonctionne sur iOS/Android/macOS
- `PRAGMA journal_mode=WAL` activé pour de meilleures performances concurrentes
- Constructeur `in_memory()` pour les tests

### `infrastructure/json_store.rs`
`JsonStore { dir: PathBuf }` — conservé pour compatibilité et tests existants.
`#[serde(alias = "style")]` sur `styles` pour la compat avec les anciens fichiers.

### `ffi/` + `pinkha.udl` — Couche UniFFI
Façade publique exposée à Swift via UniFFI 0.32.
- `PinkhaError` FFI : enum `NotFound { id }`, `InvalidOperation { detail }`, `Storage { detail }` — devient un `enum` Swift natif
- `LeafMetaFfi` / `BookMetaFfi` : structs dictionnaire (id, title_plain, title_json, cover, updated_at, created_at)
- `PinkhaApi` : ouvre les deux stores SQLite au même chemin, expose toutes les opérations leaves et books
- Les blocs et books complètes transitent en JSON (String) pour éviter le type récursif `Block` dans l'UDL — Swift décode via `Codable`
- `add_block` retourne l'UUID du bloc créé (pas le leaf entier)
- Shift+Enter géré côté éditeur : `EditorState.insert('\n')` + `save_edited_block` — aucun variant `LineBreak` nécessaire dans le modèle

Usage Swift :
```swift
let api = try PinkhaApi(dbPath: path)
let id  = try api.createLeaf(title: "Ma note")
let json = try api.getLeafJson(id: id)  // → Codable
```

#### Runtime Tokio pour les extractors reqwest

UniFFI 0.32 ship son propre foreign-task executor, **qui n'est pas un runtime Tokio**. Un futur reqwest poll sous cet executor panique avec `there is no reactor running, must be called from the context of a Tokio 1.x runtime` — reqwest enregistre ses IO directement avec Tokio.

Pattern utilisé dans `ffi/extractors.rs` pour contourner :
1. Singleton process-wide via `OnceLock<tokio::runtime::Runtime>` (multi-thread, 2 workers, `enable_all()`)
2. La méthode FFI est déclarée **synchrone** (pas `async fn`, pas `[Async]` dans le UDL)
3. À l'intérieur, on `tokio_runtime().block_on(extractor.run(...))`
4. Swift dispatche depuis `Task.detached(priority: .userInitiated)` pour ne pas geler le main thread

Cf. `import_from_notion` comme référence — les futurs extractors qui font de l'I/O réseau (Google Keep API, Apple Notes export, etc.) doivent suivre ce pattern. Les extractors purement sync (Bear via `rusqlite`, Craft via `realm-codec`) peuvent rester `async fn` UniFFI sans souci, car ils n'attendent rien qui exige un reactor Tokio.

### Détails par package — points d'attention

**Miroirs Codable FFI** (`PinkhaFFI`) :
- `LeafFfi`, `BookFfi`, `BlockFfi`, `InlineTextFfi`, `InlineStyleFfi`, `BlockContentFfi`, `PropertyFfi`, `PropertyValueFfi`, `ViewFfi`, etc. — tous `Codable`, avec `init(from:)` / `encode(to:)` custom pour le format externally-tagged de serde.
- Inits publics memberwise pour `InlineTextFfi`, `BlockFfi`, `PropertyFfi` (auto-synth Swift = internal pour structs publics).
- Helpers sur `BlockContentFfi` : `plainText`, `spansOrEmpty`, `isTodo`, `doneTodo`, `withText`, `withSpans`, `toAttributedString`.

**RichTextEditor** (`PinkhaRichText`) :
- `ExpandingTextView : UITextView` — hauteur auto via `intrinsicContentSize`, hooks pour Shift+Enter et toggles bold/italic/underline (clavier hardware).
- `RichTextEditor : UIViewRepresentable` — bindings `spans` / `isFocused`, init public à 33 paramètres (callbacks + accent + theme + keyboard appearance + mention lookup…).
- `spansToAttributed` / `attributedToSpans` — conversion aller-retour avec `NSAttributedString.Key.pinkhaColor` pour préserver le nom de couleur (round-trip fiable).
- `MenuButton : UIButton` — détecte la fermeture des menus déroulants (hide-on-menu façon Notes.app) via `contextMenuInteraction(_:willEndFor:)`.
- Toolbar pill iOS 26 : `UIVisualEffectView(UIGlassEffect())`, ordre Coller / Aa (B/I/U/S) / Highlighter / ¶ (block color) / Undo / Redo / Outdent / Indent / Return / Dismiss.
- `markdownShortcut(for:)` (free function, testable) : `# `→H1, `## `→H2, `### `→H3, `> `→Quote, `!! `→Callout, `[ ] `→Todo, `---`→Divider.
- Optim : `lastSyncedSpans` par Coordinator (skip recomputation sur blocs non modifiés), `lastCanUndo`/`lastCanRedo` (évite recréation UIImage des boutons toolbar).
- `textViewDidChange` → `save()` à chaque frappe → burst undo VM-side, persist SQLite différé au flush du burst (1 write par burst, pas par caractère).

**ContentView** (`app/Sources/App/`) :
- 4 onglets iOS 26 `TabView` + `Tab` : Library | Books | Inbox | Search.
- Délègue le rendu à `LibraryView`, `BooksHomeView`, `InboxView`, `SearchView` (chacun dans son feature target).
- Owner de `Composer`, `AppSettings`, `TabManager`, `PinkhaStore` via `@State`/`@StateObject`.
- Hoste les sheets globaux (create, import, all-leaves switcher, trash, settings, attach-to-book).

**LeafView + LeafViewModel** (`LeafFeature/Editor/`) :
- `EditableBlock : Identifiable, Equatable` — modèle en mémoire : `id`, `content: BlockContentFfi`, `spans: [InlineTextFfi]`, `done: Bool`, `color/backgroundColor/textDirection`.
- `LeafViewModel : @Observable, @MainActor` — `load`, `saveBlock` / `saveBlock(id:spans:)` (burst), `persistBlock` (structurel), `addBlock`, `deleteBlock`/`deleteBlocks(ids:)`, `moveBlock`, `applyBlockOrder`, `toggleBlockDone`, `updateBlockIcon`, `convertBlockContent`, `saveTitle`, `saveCover`.
- Mutations en mémoire directe (pas de rechargement SQLite après insert/delete — évite l'effacement du contenu en cours d'édition).
- Blocs supportés : Text, Heading (1/2/3), Quote, Callout (Quote + icône emoji), Todo, Divider, BulletedListItem, NumberedListItem, Code, Page, Book, Embed, Breadcrumb.
- `ForEach($vm.blocks) { $block in }` — two-way binding pour l'édition en place.
- Drag & drop natif via `.onMove` + `EditMode`, swipe-to-delete + menu contextuel, `.scrollDismissesKeyboard(.interactively)`, `autoFocusId` (focus auto sur bloc créé OU réinséré via undo).

**Undo / redo unifié** :
- `UndoManager` natif, `levelsOfUndo = 1000` (aligné sur la capacité du back Rust).
- 2 UI synchronisées : pill glass en bas-gauche (clavier fermé) + boutons dans la toolbar clavier (clavier ouvert).
- `canUndoProvider`/`canRedoProvider` = closures live qui lisent `vm.canUndo`/`vm.canRedo` → toujours frais à chaque `updateUIView` / `textViewDidChange` / `didChangeSelection`.
- `vm.canUndo = undoMgr.canUndo || !blockBurstAnchor.isEmpty` — le bouton s'allume aussi quand un burst de typing est pending.
- Toutes les ops VM enregistrent leur inverse : add/delete/move block, toggle todo, change icon, convert content, save title, save cover, frappe.
- **Burst undo** (style Notes) : rafale continue de `saveBlock` sur même bloc = 1 seule étape undo. `burstInterval = 300 ms` d'inactivité → flush + persist SQLite + register undo. Switch de bloc flush l'ancien immédiatement.
- `BlockSnapshot { content, spans, done }` (Equatable) — état capturé pré-burst.
- `applyBlockSnapshot(blockId:snapshot:)` remplace l'élément entier dans `blocks` + persiste + re-register la reverse.
- Observer `NSUndoManagerCheckpoint` async-dispatché → évite le warning « Publishing changes from within view updates ».

**Resilience** (`PinkhaCore/Resilience.swift`) :
- `PinkhaError.userMessage` (FR), `isRecoverable`, `tryCatch(into: &errorMessage)`, `.errorAlert(message:onRetry:)`.

### Fraîcheur du FFI — `utilities/scripts/ensure-ffi-fresh.sh`

UniFFI grave un checksum d'API dans `pinkha.swift` **et** dans la
bibliothèque Rust compilée. S'ils divergent, `uniffiEnsurePinkhaInitialized()`
appelle `fatalError` au premier `PinkhaApi(...)` : l'app meurt au lancement,
sans dialogue. C'est arrivé en vrai (Sentry `APPLE-IOS-1S`, six occurrences).

Le xcframework est gitignoré et construit localement, donc la garde de dérive
en CI ne peut pas le voir. `run-on-sim.sh` et `run-on-device.sh` appellent
maintenant `ensure-ffi-fresh.sh`, qui reconstruit quand une source Rust, le
`.udl`, `Cargo.lock` ou les bindings sont plus récents qu'un jeton posé après
la dernière construction réussie. ~3 min à froid, instantané à chaud.

Ne pas régénérer les bindings **après** le xcframework : ils deviendraient
l'artefact le plus récent et la garde reconstruirait à chaque lancement.

### Polices du lecteur

Les thèmes Tranquille et Calme utilisent **Newsreader** et **Playfair
Display** (SIL OFL, embarquées dans `app/Resources/Fonts/OFL/`). Elles
remplacent Publico Text et Canela Text, qui appartiennent à Commercial Type
et ne sont **pas redistribuables** — `app/Resources/Fonts/Bundled/` est
gitignoré et ne doit jamais entrer dans un commit. Choix, mesures et pièges :
`utilities/docs/FONT-SUBSTITUTION.md`.

### Sombre : niveau d'interface élevé

En sombre, iOS résout `systemBackground` en **noir pur**. `ContentView`
applique `.pinkhaElevatedSurfaces()`, qui place la fenêtre au niveau
*elevated* d'UIKit — page `#1C1C1E`, rangées `#2C2C2E`. Ne pas « corriger »
ça en forçant une couleur sur la page seule : les rangées gardent la leur et
l'écart tombe de 28 à 3 points de luminance, rendant les cartes moins
lisibles. Mesuré. Cf. `ElevatedInterfaceLevel.swift`.

### Minimisation de la barre de navigation : figer la zone sûre

`LeafNavBarMinimizationModifier` applique
`.toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)`. Il **doit**
rester accompagné de
`.toolbarMinimizationSafeAreaAdjustment(.disabled, for: .navigationBar)`.

Par défaut la zone sûre suit la barre pendant qu'elle se rétracte, pour que le
contenu occupe la place libérée. Mais changer la zone sûre d'un `ScrollView`
déclenche `_notifyDidScroll`, que l'observateur de défilement de la barre
écoute pour décider de sa hauteur — laquelle redéfinit la zone sûre. C'est un
cycle.

Hors transition il s'amortit : chaque tour attend l'image suivante. En tapant
un onglet depuis une leaf, la mise en page est **synchrone**
(`layoutBelowIfNeeded` sous `performWithoutAnimation`) : plus de frontière
d'image, le cycle tourne sur place, l'app gèle à 100 % de CPU avec les deux
écrans composités l'un sur l'autre. Profil d'un gel réel :

```
_UIViewControllerTransitionConductor startDeferredTransitionIfNeeded
  → performWithoutAnimation → layoutBelowIfNeeded
      → UIView _updateSafeAreaInsets
          → UIScrollView setSafeAreaInsets: → _notifyDidScroll
              → UINavigationController _observeScrollViewDidScroll:topLayoutType:
                  → _edgeInsetsForChildViewController:  (et on recommence)
```

`.disabled` fige la zone sûre pendant la rétraction : la barre se rétracte
toujours (le réglage d'accessibilité est préservé), mais plus rien ne reboucle.
Apple documente ce cas comme « utile quand le contenu passe sous la barre » —
soit une leaf à couverture, qui pose déjà `.ignoresSafeArea(.top)`.

> ⚠️ Ce gel a résisté à **six** bisections par hypothèse. Ce qui l'a trouvé :
> échantillonner le processus *pendant* le gel (`sample <pid>`) et lire l'épine
> à forte densité, pas relire le code. Deux fausses pistes coûteuses : la barre
> d'onglets du **bas** (`tabBarMinimizeBehavior`, testée et innocentée) et le
> nombre de blocs (800 blocs ne reproduisent rien). Le gel n'a **jamais** été
> reproduit automatiquement — la validation est passée par une bisection à deux
> coups sur l'appareil.

Corollaire testé à part : `titleInNavBar` compare
`contentOffset.y + contentInsets.top` à un seuil alors que sa réaction modifie
cet inset. `titleShouldEnterNavBar(offset:currently:)` porte une zone morte
40–60 pt pour que ce drapeau ne puisse pas osciller. Nécessaire, mais pas
suffisant seul : la rétraction déplace l'inset de bien plus de 20 pt.

### iOS 27 — `.reorderable()` avale les modificateurs posés dans la rangée

Sur iOS 27, `.reorderable()` ne laisse pas survivre les modificateurs de rangée
appliqués **à l'intérieur** de la vue de rangée. Ils doivent être posés sur le
`ForEach`.

Deux bugs visuels distincts en sont déjà venus :

- `.listRowSeparator(.hidden)` — un trait réapparaissait entre chaque bloc,
  donnant l'illusion qu'un Divider était inséré à chaque retour à la ligne
- `.listRowBackground(Color.clear)` — les blocs reprenaient le fond de rangée
  système, qui recouvrait le papier du thème. Le thème ne s'affichait plus que
  derrière l'en-tête (couverture, icône, titre), hors du `ForEach`. Mesuré :
  `#423B30` en haut, `#1C1C1E` en dessous

Règle : quand `.reorderable()` est là, **tout** modificateur `listRow*` se pose
sur le `ForEach`, jamais dans `blockListRow`.

### Fond de page : calque à la racine, pas `.background` sur la liste

Le fond du thème d'une leaf est un frère du `ScrollViewReader` dans un `ZStack`,
à la racine de `LeafView.body`. Il ne doit **pas** revenir en `.background(...)`
sur la liste.

En `.background`, il est soumis à la zone sûre : le papier s'arrête sous la
barre d'état, au-dessus de la barre d'onglets, et sous la pastille du clavier.
Corriger ça sur place revient à élargir l'exclusion de zone sûre de la liste —
or c'est cette même zone qui définit la fenêtre visible dont dépend l'ancre de
`proxy.scrollTo`. Un `.ignoresSafeArea()` nu y fait viser 90 % d'un écran
s'étendant sous le clavier : le bloc atterrit derrière lui et le défilement au
tap paraît mort. Deux besoins sur un seul point ; en calque séparé, ils cessent
de se disputer.

Corollaire : il n'y a plus de défilement automatique quand un bloc prend le
focus. UIKit révèle déjà le curseur seul. La version maison visait une ancre
définie par cette zone sûre — retirée sur demande après l'avoir constaté.

### Quand deux hypothèses tombent, instrumenter

Ce projet l'a prouvé deux fois dans la même journée (2026-08-11) :

- le gel au changement d'onglet a résisté à **six** bisections par hypothèse ;
  `sample <pid>` pendant le gel a donné la réponse en une lecture (PRO-144)
- le placement du curseur a résisté à **sept** hypothèses ; trois captures de
  `textViewDidChangeSelection` ont livré le fait établi (PRO-145)

Deviner coûte un aller-retour utilisateur par essai. Mesurer coûte un build.
Au-delà de deux hypothèses infirmées, instrumenter — journal horodaté, identité
de l'objet observé, pile d'appels — plutôt que d'en formuler une troisième.

Deux pièges rencontrés en instrumentant : `NSLog` tronque les messages longs
(imprimer une trame de pile par ligne), et un journal qui n'identifie pas
l'objet observé mélange les instances — toutes les vues de texte partagent le
même délégué.

### Sauvegarde : l'instantané se fait en Rust, jamais par copie de fichier

`PinkhaApi::export_library(dest_path)` fait un `VACUUM INTO` depuis la
connexion vivante et renvoie la taille écrite. Swift ne copie **jamais**
`pinkha.db` lui-même.

La raison est mesurable : en mode WAL, la fin des écritures validées vit
encore dans `pinkha.db-wal` tant qu'aucun point de contrôle n'a eu lieu. Une
copie du seul fichier principal expédie donc une base amputée de ses écritures
les plus récentes — précisément celles auxquelles l'utilisateur tient le plus.
`VACUUM INTO` replie le journal dans un fichier unique et défragmenté, sans
annexes à transporter.

`LibraryExport.makeArchive` (PinkhaCore) assemble l'instantané, le dossier
`Covers/` et un `LISEZ-MOI.txt`, puis compresse via
`NSFileCoordinator(readingItemAt:options:[.forUploading])` — le mécanisme
système, sans dépendance tierce. L'option conserve le **dossier racine** dans
l'archive, d'où son nom lisible par un humain.

La feuille de partage passe par `UIActivityViewController` et non par
`fileExporter` : ce dernier exige un `FileDocument`, donc un `Data` en
mémoire, et une bibliothèque avec ses couvertures pèse plusieurs dizaines de
mégaoctets.

> ⚠️ `SettingsView` reçoit le store par injection explicite
> (`SettingsView().environment(store)`). Une feuille iOS 26 ne propage pas de
> façon fiable l'environnement de la vue qui la présente ; sans cette ligne le
> bouton d'export reste grisé, silencieusement.

**Pourquoi cette fonctionnalité existe.** Le 2026-09-02, la base d'un appareil
réel s'est retrouvée vide du jour au lendemain : fichier de 4 Ko, zéro ligne,
schéma intact. Les couvertures avaient survécu au même endroit, et aucun code
de l'app ne peut supprimer ce fichier (`auto_vacuum` est à 0, donc une
suppression de lignes ne réduit pas le fichier ; et `delete_all_leaves` fait
une suppression *douce*). Cause non élucidée, appareil sous iOS bêta. Sept
années d'écrits n'ont tenu qu'à une copie oubliée sur un simulateur, restaurée
à la main via `devicectl device copy to`. Les fichiers d'origine du téléphone
sont conservés hors dépôt dans un dossier `pinkha-rescue-*`.

### Instantanés automatiques : à CÔTÉ de la base, jamais dedans

`snapshot_library(dir, keep)` écrit `pinkha-YYYYMMDD-HHMMSS.db` dans `dir` et
n'y garde que les `keep` plus récents. L'horodatage UTC en tête du nom rend
l'ordre alphabétique équivalent à l'ordre chronologique — la purge n'interroge
donc jamais le système de fichiers pour savoir qui est vieux. Elle ne touche
que les fichiers portant le préfixe `pinkha-` et l'extension `.db` : un dossier
partagé ne doit jamais voir disparaître ce qui ne nous appartient pas.

Côté Swift, `LibrarySnapshots.runIfDue` est appelé au passage en arrière-plan
(`scenePhase == .background` dans `ContentView`). Ce moment est le bon : plus
personne ne regarde l'écran, aucune frappe n'est en cours donc la base est
cohérente, et iOS accorde encore un court sursis. Cadence : 6 h, 7 copies —
soit une semaine de dégâts silencieux avant que la dernière copie saine ne
soit écrasée.

Destination : **iCloud Drive d'abord, local en repli**.
`LibrarySnapshots.destination()` tente
`url(forUbiquityContainerIdentifier:)` puis retombe sur
`Application Support/Pinkha/Snapshots/`. Le repli n'est pas cosmétique : le
conteneur vaut `nil` quand l'utilisateur n'est pas connecté à iCloud, quand
il a coupé iCloud Drive pour l'app, ou quand la build n'a pas les droits —
trois situations ordinaires. Refuser de sauvegarder là punirait exactement
ceux qui n'ont pas de sauvegarde iCloud.

Le dossier iCloud vit sous `Documents/` du conteneur et `Info.plist` déclare
`NSUbiquitousContainerIsDocumentScopePublic` : il apparaît donc dans l'app
Fichiers sous « Pinkha ». Une sauvegarde qu'on ne peut atteindre que depuis
l'app qui a perdu les données ne vaut pas grand-chose.

Le repli local est **frère** de `pinkha.db` et non enfant. Lors de la perte
du 2026-09-02, `pinkha.db` a disparu tandis que le dossier frère `Covers/`
est resté intact. Ce n'est pas une preuve, mais c'est la seule observation
disponible et elle ne coûte rien à suivre.

Droits : `app/Sources/Pinkha.entitlements` déclare
`CloudDocuments` (des fichiers dans iCloud Drive), **pas** `CloudKit` — la
synchro d'enregistrements entre appareils reste un chantier distinct. La
signature automatique a provisionné le conteneur sans intervention dans le
portail développeur ; vérifié avec `codesign -d --entitlements -` sur la
build appareil.

`LibrarySnapshots` n'est délibérément **pas** `@MainActor` : l'écriture est
bloquante et doit rester hors du fil principal.

> ⚠️ Présenter une feuille depuis `onAppear` rouvre la récursion de mise à
> jour documentée dans `LeafView`. L'ouverture automatique des réglages sous
> test (`--ui-test-settings`) passe par `.task`, qui s'exécute sur un tour de
> boucle neuf. Avec `onAppear`, l'app rendait un écran noir et XCUITest
> n'obtenait jamais l'arbre d'accessibilité (`kAXErrorServerNotFound`).

### ⚠️ Les tests XCUITest ne passent plus — l'app ne se déclare jamais au repos

Constaté le 2026-09-02 : XCUITest n'obtient plus l'arbre d'accessibilité de
l'app. Les requêtes échouent en `Timed out while evaluating UI query` ou
`Error getting main window kAXErrorServerNotFound`, précédées de :

```
t = 64.29s   App event loop idle notification not received, will attempt to continue.
```

Touche des tests **préexistants** — `testAppLaunchesAndShowsGreeting`,
`testFloatingButtonOpensCreateSheet`, `testCancelCreateSheetClosesIt` —
donc indépendant de toute fonctionnalité récente. Vérifié par bisection :
l'échec est identique avec et sans les changements en cours.

L'app se lance et s'utilise normalement à la main ; seul XCUITest est
aveugle. La cause est donc une animation ou une boucle de mise à jour qui
ne s'arrête jamais sur l'écran d'accueil — famille déjà nommée plus haut
(écriture non gardée dans un rappel de mise en page). À traiter par
instrumentation, pas par hypothèses : `sample <pid>` pendant que le test
attend donnera l'épine en une lecture.

**Conséquence pratique** : le troisième niveau de la pyramide de tests est
hors service. Les fonctionnalités livrées entre-temps le sont avec une
couverture unitaire et d'intégration seulement, et le test UI correspondant
est à écrire une fois ce défaut corrigé.

## Roadmap

Ce qui est **fait** — backend Rust + UI SwiftUI :
- Parser inline complet (bold, italic, underline, color, link, combinaisons)
- Types de blocs et leaves avec blocs imbriqués récursifs
- `LeafMeta` pour `list()` sans charger tout le contenu
- Erreurs custom `PinkhaError` (plus de `Box<dyn Error>`)
- `RichText` + `EditorState` : édition en mémoire (curseur, sélection, toggle style)
- Undo/redo via pattern Command côté Rust (`History` avec capacité configurable)
- Moteur book type Notion (propriétés, entrées, vues, filtres, tris, rollup, relation)
- CRUD complet blocs : ajouter, modifier, supprimer, réordonner (racine et enfants), imbriquer, déplacer
- Recherche leaves par titre + plein texte dans les blocs
- Recherche dans les entrées de book
- Gestion complète des propriétés (ajout, renommage, suppression)
- Gestion complète des vues (ajout, modification filtres/tris, suppression)
- **SQLite local-first** : `SqliteLeafStore` + `SqliteBookStore` avec soft delete, `updated_at`, migrations versionnées, WAL, retry exponentiel
- **Crate `chaqaq` v0.1.0** : core rich text editor extrait en crate autonome, publié sur crates.io (MIT OR Apache-2.0). Cargo workspace.
- **Crate `realm-codec` v0.1.0** : parser + writer Realm v9 binary (NodeHeader, Group, B-tree, cluster tree format Realm SDK 5+, `RealmBuilder`/`TableBuilder`), publié sur crates.io (MIT OR Apache-2.0). Utilisé par l'extractor Craft.
- **Couche FFI UniFFI** : `PinkhaApi` exposée à Swift en API anglaise idiomatique
- **XCFramework** : `pinkha.xcframework` compilé (ios-arm64, ios-arm64-simulator, macos-arm64)
- **Projet Xcode** : `app/Pinkha.xcodeproj` généré par xcodegen
- **UI SwiftUI** :
  - **Tab bar 4 onglets** (iOS 26 `TabView` + `Tab`) : Library | Books | Inbox | Search. La bulle Search détachée exige **`.tabViewSearchActivation(.searchTabSelection)`** sur le TabView : depuis iOS 27 ce traitement est le « prominent tab », réservé aux onglets dont `UISearchTab.automaticallyActivatesSearch` vaut `true` (défaut `NO`). `Tab(role: .search)` **seul ne détache pas**.
  - **Notes** : salutation dynamique, strip horizontale "Récents" (5 derniers docs, cards Apple Music style), liste complète avec swipe-to-delete, FAB `square.and.pencil`
  - **Bases** : placeholder (backend Notion complet côté Rust, UI à venir)
  - **Recherche** : `searchable` SwiftUI + `api.searchLeaves(query:)` FFI, résultats en temps réel
  - Éditeur de leaf : blocs Text, Heading (×3), Quote, Callout (Quote + emoji), Todo, Divider
  - Texte riche : gras, italique, souligné, barré, 9 couleurs (rouge, rose, orange, jaune, vert, cyan, bleu, violet, marron)
  - Toolbar pill (style Notes.app) glass effect : Coller / Aa (B/I/U/S) / Highlighter / ¶ (block color) / Undo / Redo / Outdent / Indent / Return / Dismiss — hide-on-menu façon Notes
  - **Block color** : `Block.color: Option<String>` côté Rust, palette ¶ dans la toolbar (même palette que le highlighter), priorité inline > block au render (un span sans inline color hérite, un span avec inline color override) — toute la chaîne validée Rust + UI + import Notion + best-effort Craft
  - **Indent / outdent** : boutons `increase.quotelevel` / `decrease.quotelevel` dans la pill, FFI Rust dédié (`indent_block` / `outdent_block`) qui gère le positionnement (outdent place le bloc juste après l'ancien parent, pas en fin de liste)
  - Raccourcis markdown : `# `, `## `, `### `, `> `, `!! ` (callout), `[ ] `, `---`
  - Enter → nouveau bloc, Shift+Enter / Return toolbar → saut de ligne dans le bloc, drag & drop, swipe-to-delete, dismiss clavier par swipe
  - Focus automatique sur le bloc créé OU réinséré via undo
  - Undo/redo unifié (1000 niveaux) : pill bas-gauche + boutons toolbar, burst typing 300 ms style Notes, focus auto sur block réinséré
  - Perf : persist SQLite différé au flush burst, cache spans par bloc, cache état boutons undo
- **CI** : GitHub Actions `cargo test` sur push/PR vers master/staging/dev (`macos-15`). Swift job suspendu en attendant Xcode 26 sur les runners
- **Architecture modulaire Swift** : 6 packages SwiftPM (10 targets) avec un DAG enforced par le compilateur (cf. section Architecture). L'app target ne contient plus que le composition root (`App/` + `Resources/`).
- **Vocabulaire métier "Library/Leaf/Book/Shelf/Compost"** appliqué à tout le code (Rust + Swift + SQLite tables + i18n EN/FR + docs). Cf. `utilities/docs/VOCABULARY.md`.
- **Sécurité repo** : branches protégées (PR obligatoire, force-push bloqué, suppression bloquée, Rust CI requise), Secret Scanning + Push Protection, Dependabot Alerts + Security Updates, Dependabot config mensuelle pour Cargo + Actions, job CI `cargo-audit --deny warnings` (scan CVE à chaque PR)
- **Stockage secrets** : `Keychain.swift` (wrapper minimal `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, jamais synchronisé iCloud) pour les tokens d'API. Token Notion persisté après import réussi seulement. OAuth2 client secret JAMAIS embarqué dans le binaire iOS — `NotionOAuth2.tokenProxyUrl` pointe vers un backend proxy qui détient le secret.
- **Architecture OAuth2 Notion** (multi-tenant) — modèle "1 paire de credentials d'app, N tokens utilisateurs" :
  - Credentials de l'app (`NOTION_CLIENT_ID` + `NOTION_CLIENT_SECRET`) = identifient l'app pinkha auprès de Notion. **Une seule paire pour toute l'app, jamais dans le binaire iOS, jamais dans le repo.** Vit uniquement dans les env vars de la fonction Lambda du proxy (et dans `notion-proxy/.env` gitignored en local).
  - Access token utilisateur = scoped à un workspace Notion donné. Généré au runtime via le flow authorization-code, retourné par le proxy à l'app, stocké dans le Keychain iOS (par-device, jamais sync iCloud).
  - **HTTPS callback bridge** : Notion rejette les custom URL schemes en redirect URI depuis 2024. Le `redirectUri` envoyé à Notion pointe sur `https://<proxy>/oauth/callback` ; cette route fait un `302` vers `pinkha://oauth/notion?code=...` que `ASWebAuthenticationSession` (`callbackURLScheme: "pinkha"`) capture pour revenir dans l'app. Pas de HMAC sur ce GET (browser-initiated, `code` Notion single-use et short-lived).
  - Flow concret par user (Alice ouvre l'app distribuée App Store) : (1) `ASWebAuthenticationSession` ouvre `api.notion.com/v1/oauth/authorize?client_id=...&redirect_uri=https://proxy/oauth/callback` (2) Alice login avec son compte Notion → consent screen "Authorize pinkha?" (3) Notion redirige le browser vers `https://proxy/oauth/callback?code=...` (4) le proxy renvoie un `302 pinkha://oauth/notion?code=...` (5) iOS rouvre l'app via le custom scheme (6) app POST `code` à `https://proxy/oauth/token` avec HMAC (7) proxy combine `code` + `client_secret` → `api.notion.com/v1/oauth/token` (8) Notion retourne un `access_token` propre à Alice (9) proxy renvoie le token, app le persiste en Keychain.
  - Bob fait pareil → token distinct. Les users n'ont jamais à connaître les credentials de l'app.
  - **Configuration côté Swift** : une seule clé Info.plist `NOTION_PROXY_URL` (injectée depuis `app/Config/Secrets.xcconfig`) configure le base URL ; `redirectUri` = `\(base)/oauth/callback`, `tokenProxyUrl` = `\(base)/oauth/token`. `NotionOAuth2.proxyBaseUrl` lit la valeur au runtime.
  - **Setup release App Store** : créer une Notion integration **Public** (pas Internal), ajouter `https://<api-id>.execute-api.<region>.amazonaws.com/oauth/callback` comme redirect URI (HTTPS obligatoire), configurer les 4 env vars sur la Lambda (`NOTION_CLIENT_ID`/`SECRET`, `PROXY_HMAC_SECRET`, `SENTRY_DSN`) via `cargo lambda deploy --env-file .env`, mettre cette même base URL dans `NOTION_PROXY_URL` du `Secrets.xcconfig`. Tout user public est ensuite supporté sans config additionnelle.
  - **Hébergement du proxy** : AWS Lambda (ARM64) derrière une API Gateway HTTP API, et non une Function URL — le compte AWS refuse les Function URLs anonymes, et `/oauth/callback` est une redirection navigateur qui ne peut pas être signée en SigV4. Voir `notion-proxy/CLAUDE.md`.
- **Observabilité (Sentry)** : crash reporting + tracing distribué via [sentry-cocoa](https://github.com/getsentry/sentry-cocoa) 8.49+ (SPM).
  - DSN dans `app/Config/Secrets.xcconfig` (gitignored) + `Secrets.xcconfig.example` (template commit), injecté dans `Info.plist` via build setting. `https://` doit être échappé en `https:/$()/` (xcconfig interprète `//` comme commentaire).
  - Wrapper `app/Packages/PinkhaCore/Sources/PinkhaCore/Observability.swift` — `start()` no-op silencieux quand DSN absent ou placeholder, `capture(_:)` / `capture(message:)` safe pré-init.
  - Init au démarrage dans `PinkhaApp.init()`. Hook `tryCatch(into:)` dans `Resilience.swift` capture les `PinkhaError.Storage` (transient) + toutes les erreurs non-typées. `NotFound` / `InvalidOperation` restent silencieux (états utilisateur attendus, pas des bugs).
  - **Distributed tracing** : `enableAutoPerformanceTracing` propage automatiquement le header `sentry-trace` sur les requêtes URLSession (vers `notion-proxy` notamment). Aucun code custom requis dans `NotionOAuth2.swift`.
  - 2 projets Sentry séparés dans l'org `Pinkha-app` : `apple-ios` (app) + `notion-proxy` (backend). `tracesSampleRate` à 1.0 en debug, 0.2 en release.
- **Pipelines d'extraction** (`src/extractors/`) :
  - Architecture `Extractor` trait (async, `Config` associé, `ImportResult`)
  - **Notion** : client reqwest rustls-tls, API v1 paginée (book schema → pages → blocs récursifs), mapping complet propriétés/valeurs/blocs. **FFI synchrone** (`block_on` un `tokio::runtime::Runtime` singleton via `OnceLock`) — UniFFI 0.32 n'expose pas de reactor Tokio, mais reqwest en exige un. Swift dispatche via `Task.detached`. Flow OAuth2 + token exchange + import end-to-end validés sur device le 2026-06-02 (token Notion reçu via le proxy — hébergé sur Railway à cette date, migré sur AWS Lambda depuis —, import book → SQLite local-first OK). Block colors mappées via `map_block_color`. **2-pass mention rewriting** : un map `NotionPageId → PinkhaDocId` est construit pendant l'import, puis chaque doc est revisité pour remplacer les `https://notion.so/...{page_id}` en `pinkha://doc/{uuid}` (les mentions internes pointent désormais sur les notes pinkha importées, plus sur Notion).
  - **Bear** : lecteur SQLite read-only, conversion timestamps Core Data, parseur Markdown Bear ligne par ligne
  - Trois nouveaux variants `BlockContent` : `BulletedListItem`, `NumberedListItem`, `Code` — full-fidelity import, rendu read-only + édition dans l'éditeur
  - **Craft** : lecteur Realm v9 binary read-only via `realm-codec` (crate library), heuristique `rawProperties.titleEnabled == "true"` pour détecter les pages, 2498 docs / 4224 blocs / 41 skipped sur fichier réel
  - `NotionImportView.swift` (thin FFI wrapper) + `BearImportView.swift` (fileImporter) + `CraftImportView.swift` (fileImporter `.realm`) + `NotionOAuth2.swift` (ASWebAuthenticationSession)
  - FAB menu : "Import from Notion" + "Import from Bear" + "Import from Craft"

Ce qui **reste** à construire :
1. **UI Books** — vue table + sort par colonne, mais manque : filtres UI complets, switch entre views (Kanban/Calendar/Gallery) toujours en cours, tri multi-colonnes, link picker pour Relation. Cf. `utilities/docs/UI-AUDIT.md`.
2. **Vue iPad / Mac** (NavigationSplitView)
3. **Sync entre appareils** (CRDT — s'inspirer de y-octo) — `updated_at` et soft delete déjà en place
4. **Réactiver Swift CI** quand Xcode 26 sera dispo sur les runners GitHub Actions
5. **Import fidelity** — cover/icon Notion, image/file blocks, mapping views/filters Notion. Audit complet dans `utilities/docs/IMPORT-AUDIT.md`.
6. **Synchro CloudKit entre appareils** — l'export manuel et les instantanés automatiques (iCloud Drive avec repli local) sont en place. Reste la synchro d'enregistrements, chantier distinct qui rejoint la ligne CRDT de la feuille de route.
7. **Localizable.xcstrings polish complet** — pass critique fait (labels les plus visibles + verbes Bind/Unbind/Shelve/Discard), reste 3631 lignes à reviewer une par une pour la cohérence et le ton.

### Cross-domain orchestration (`application/use_cases/book_leaf_sync.rs`)
Quand une opération doit toucher plusieurs domaines (Leaf + Book), le module `book_leaf_sync` est le bon endroit — il dépend de `&dyn LeafRepository` ET `&dyn BookRepository` sans coupler les domaines entre eux. Exemple en place : `update_entry_propagating_title(docs, dbs, book_id, entry_id, values)` qui renomme un leaf quand on rename une row de DB (`Entry.leaf_id` est le lien).

### `Entry.leaf_id: Option<Uuid>`
Lie une row de DB au leaf qui la sous-tend (Notion-style : row = page). Set par les imports (`add_entry_with_leaf`), `None` pour les rows tabulaires purs. Le FFI `update_entry` route désormais vers `update_entry_propagating_title` — la propagation du Title vers le doc est transparente côté Swift. Le FFI `attach_leaf_to_book(book_id, leaf_id, values_json)` expose le même use case à l'UI pour filer une note existante comme row d'une DB après coup (long-press All/Recents + overflow menu de l'éditeur).

### `published_at` (Leaf + Entry)
Tous deux exposent `published_at: String` user-éditable, distinct de `created_at` (immuable). Empty string = "follow `created_at`" (sentinel traité côté `SortSource::Published`). SQLite tient une colonne dédiée (backfill = `created_at` à la migration). UI : sheet `LeafPublishDateSheet` (overflow menu du leaf) + `PublishDatePickerSheet` (context menu d'une row de Book) + `SortSource::Published` dans le `sortMenu` côté Book + `SortKey.publishedAt` dans `LibraryView+Sort`. Use cases : `update_leaf_published_at`, `update_entry_published_at`. FFI tronque à 64 bytes (taille RFC 3339).

### Import Notion — concurrence, annulation, link_to_page
- **Concurrence** : `stream::buffered(3)` sur le fetch des pages (calé sur la rate limit ~3 req/s de Notion). `import_page` ne crée plus l'entry lui-même — il retourne les valeurs et le consommateur insère séquentiellement dans l'ordre Notion (le load-modify-write du blob book ne race jamais). Map notion→pinkha sous `Mutex`.
- **Annulation** : `extractors::cancel` (AtomicBool process-wide), FFI `cancel_import()`. Le loop vérifie entre chaque page ; sur cancel → `purge_partial_import` (hard delete de tous les docs créés + la book, rien en corbeille) → `ExtractorError::Cancelled` → message calme côté Swift. Rollback par compensation — le vrai UoW transactionnel SQL reste en dette.
- **`link_to_page`** : mappé en paragraphe portant un lien `notion.so/{page_id}` — le pass 2 le réécrit en `pinkha://doc/` et la promotion en fait un bloc `Page` quand la cible est dans l'import ; sinon le lien notion.so reste cliquable.

### Cascade delete / restore des books
`delete_book_cascade` / `restore_book_cascade` (book_leaf_sync, FFI homonymes) : la suppression/restauration d'une DB embarque les leaves liés (`Entry.leaf_id`), docs déjà traités skippés (`NotFound`). UI : `BookCascadeDialogs.swift` — confirmationDialogs partagés (« & its pages » / « only ») branchés sur BooksHome, NotesHome (swipe) et Trash. Les chemins bulk-selection restent DB-only.

### Sort par vue (Book) — un seul point d'hydratation
Chaque `View` possède son propre tri. `BookViewModel.hydrateViewConfig(from:)` est **le** seul endroit qui lit `view.sorts` + `dateGrouping` ; il est appelé depuis `load()`, `activateView()` et `addView()`. Trois bugs ont vécu là : lecture depuis `allViews.first` au lieu de la vue active, absence de re-hydratation au changement de vue, et héritage du tri en mémoire par une vue neuve. Un quatrième dessous : `applySort`/`setDateSort` persistaient via FFI sans rafraîchir le cache `views` que l'hydratation relit — le tri disparaissait de l'UI en changeant de vue tout en restant sur disque. `cacheViewSort` miroite l'écriture. Trois tests d'intégration verrouillent reopen / switch-and-return / vue neuve.

### Lock book — 3 niveaux
Le header locké rend du `Text` statique (pas un TextField `.disabled` — bypassable sur device iOS 26 avec `axis: .vertical`) ; le VM ignore le commit-au-blur ; `update_book_title`/`update_book_description` refusent en `InvalidOperation` côté Rust.

### `Book.published_at_source: Option<Uuid>`
Colonne Date qui pilote le `published_at` de chaque row (et du doc lié). Adoption = backfill de toutes les entries ; clear = reset au sentinel "suit `created_at`". Sync vivante : `add_entry`/`update_entry` recalculent `published_at` quand la cellule source change (`Book::source_publish_date`), `update_entry_propagating_title` propage au leaf. Use case cross-domain `set_published_at_source(uow, book_id, Option<prop_id>)` dans `book_leaf_sync.rs`, FFI homonyme. Import Notion : auto-adoption quand exactement une prop Date porte un nom publish-flavored (`mapper::detect_publish_source` — match exact, casse-insensible : publication/published/publish date/…). UI : section "Publish date" dans `BookPropertiesSheet` (Picker None / colonnes Date).

## Git workflow

### Branches permanentes
- `master` — production. Tout ce qui est ici doit être stable, testé, releasable.
- `staging` — pré-prod / QA. Promu depuis `dev` quand un lot de features est prêt à tester.
- `dev` — intégration. Toutes les features/fixes y sont mergées avant promotion.

### Branches éphémères (à créer puis supprimer après merge)
- `feature/<nom-court>` — nouvelle feature
- `fix/<nom-court>` — bug fix
- `refactor/<nom-court>` — refactoring sans changement de comportement
- `docs/<nom-court>` — modifications de documentation uniquement
- `chore/<nom-court>` — maintenance (deps, CI, tooling…)
- `perf/<nom-court>` — optimisation de performance ciblée

### Flow
1. `git checkout dev && git pull` puis `git checkout -b feature/ma-feature`
2. Commits sur la branche, PR vers `dev`
3. Merge dans `dev` → la branche éphémère est supprimée (remote + local)
4. Quand `dev` est stable : merge `dev` → `staging` pour QA
5. Quand `staging` est validée : merge `staging` → `master` (= release)

### Règles
- **Ne jamais commit directement sur master, staging, ou dev** — toujours via PR depuis une branche éphémère.
- **Nommage en kebab-case** : `feature/undo-redo-toolbar`, pas `feature/UndoRedo` ni `feature/undo_redo`.
- **Une branche = une intention** : ne pas mélanger feature + fix + refactor dans la même branche.
- **Supprimer les branches mergées** (remote ET local) — éviter l'accumulation.

## Code style

### Langue
Tout dans le repo est en **anglais** : identifiants, commentaires, doc-comments, chaînes utilisateur, placeholders, accessibility labels. Exception unique : **CLAUDE.md** est en français.

### Conventions
- Pas de `unwrap()` — toujours `?` et `Result` côté Rust
- Nommage idiomatique : Rust `snake_case`/`PascalCase`, Swift `camelCase`/`PascalCase`
- `flush()` pattern pour les parsers

### Règle Doc-first (non négociable)

**Avant tout plan ou implémentation, consulter la doc officielle.**

Pour SwiftUI / UIKit / iOS APIs : `developer.apple.com/documentation`, les forums développeur Apple (`developer.apple.com/forums`), et les notes de WWDC les plus récentes. Pour Rust crates : `docs.rs`. Pour les frameworks SDK side : leur doc publique.

**Pourquoi non négociable** : sans la doc en main, on bricole. Exemple coûteux : le 2026-06-15, j'ai désactivé une douzaine de modifiers SwiftUI dans pinkha pour traquer un rendu menu gris en iOS 26. Une recherche initiale sur la doc Apple aurait immédiatement révélé que c'est un bug iOS 26 confirmé (FB19221675, thread Apple Developer Forums) sans workaround SwiftUI. ~2h de tâtonnement évitable.

**How to apply** : avant chaque chantier impliquant une API système ou une lib externe, premier réflexe = WebFetch/WebSearch la doc officielle + parcourir les issues/forums pertinents. Le diagnostic empirique vient APRÈS la lecture, pas avant.

### Règle Rust-first (non négociable)

**Toute opération sur les données appartient à Rust, jamais à Swift.**

Avant d'écrire un loop ou une logique de traitement en Swift, s'arrêter et implémenter dans Rust :
1. Ajouter la méthode dans le bon sous-module de `ffi/` (suivre le pattern `delete_all_leaves` comme référence)
2. L'exposer dans `pinkha.udl` (`[Throws=PinkhaError]`)
3. Rebuilder le XCFramework (`./build-xcframework.sh`)
4. Appeler le FFI depuis Swift

**Opérations qui doivent être dans Rust :**
- Mutations bulk (`delete_all_leaves`, `delete_all_books`, etc.)
- Requêtes filtrées / recherches / agrégations
- Toute logique qui touche au store SQLite

**Exceptions acceptables en Swift (UI layer uniquement) :**
- Formatage pour l'affichage (dates, nombres)
- Wrapping en enum Swift (`WorkspaceItem.note($0)`, `WorkspaceItem.book($0)`)
- `.map(\.id)` pour construire les tableaux d'UUIDs passés aux appels FFI
- Filtres de présentation sur des données déjà fetchées (ex: filtrer les propriétés système de la UI table view)

### Architecture — SOLID + Clean Architecture
- **Single Responsibility** : chaque module/type fait une chose. Domain (types purs), application (use cases + traits), infrastructure (stockage), ffi (adaptateur). Pas de "God objects".
- **Open/Closed** : ajout d'une fonctionnalité = nouveau type/impl, pas de modification des use cases. Les `match` exhaustifs forcent par le compilateur à traiter chaque variant ajouté (voulu).
- **Liskov** : toute impl de `LeafRepository`/`BookRepository` doit être strictement substituable (les tests tournent sur `MockRepo`, la prod sur `SqliteLeafStore`).
- **Interface Segregation** : un trait = un rôle. `LeafRepository` et `BookRepository` sont séparés ; un client leaves ne dépend pas des méthodes book.
- **Dependency Inversion** : les use cases dépendent d'abstractions (`&dyn LeafRepository`), jamais de stores concrets. Seul `ffi/` (composition root) connaît les implémentations concrètes (`SqliteLeafStore`).

### Résilience (back + front)
- **Erreurs typées, pas de panic** : `Result<T, PinkhaError>` côté Rust, throws/Result côté Swift. Jamais de `unwrap()`/`!` en production.
- **Conversion d'erreurs aux frontières** : `From<E>` Rust (cf. `From<CoreError> for PinkhaError` FFI) ; mapping en `PinkhaError` côté Swift via `do/catch` qui remonte un `errorMessage: String?` au store.
- **Pas de couplage à l'impl** : `PinkhaError::Db(String)` convertit les erreurs `rusqlite` en string pour ne pas coupler l'application à SQLite.
- **Retry avec backoff exponentiel** : `application/resilience.rs::retry_with_backoff` (3 essais, 50ms→500ms doublés) wrappe les opérations SQLite write/read. `is_transient()` ne retente que les erreurs verrou/I/O bloquante, jamais les erreurs métier (`NotFound`, `InvalidOperation`).
- **Validation aux frontières FFI** (`ffi/validation.rs`) :
  - `parse_uuid` rejette les UUID malformés en `InvalidOperation`
  - `parse_json` refuse les payloads > **5 Mo** (`MAX_JSON_BYTES`)
  - `check_string` refuse les chaînes > **64 Ko** (`MAX_STRING_BYTES`) — appliqué à title/query/new_name
- **Soft delete + `updated_at`** : pas d'effacement dur, préparation CRDT/sync. Toute écriture passe par `save()` qui met à jour `updated_at`.
- **Mutations UI optimistes** : mémoire d'abord (les blocs en mémoire), persistance ensuite — évite l'effacement du contenu en cours de frappe lors d'un rechargement SQLite. La désync mémoire/disque est détectée au rechargement.
- **Concurrence** : SQLite en `WAL` pour la lecture concurrente. `@MainActor` côté Swift pour les view models. Pas d'accès direct au store hors façade.
- **UX erreur Swift** (`Resilience.swift`) :
  - `PinkhaError.userMessage` → message français lisible par utilisateur (au lieu de l'erreur brute)
  - `PinkhaError.isRecoverable` → true pour `Storage` (retry possible)
  - `tryCatch(into: &errorMessage)` capture l'erreur sans propager, remonte le message au view model
  - `.errorAlert(message:onRetry:)` modificateur SwiftUI qui présente l'alert avec bouton « Réessayer » optionnel
- **Tests à 3 niveaux côté Rust** : unitaires (`#[cfg(test)] mod tests` dans chaque module — y compris `resilience.rs` avec 6 tests), intégration (`tests/integration_*`), E2E (`tests/e2e_*`). 690+ tests.
- **Tests à 3 niveaux côté Swift** : `app/Tests/Unit/` (Swift Testing — `@Suite`/`@Test`/`#expect`, code pur), `app/Tests/Integration/` (Swift ↔ FFI réelle avec DB SQLite temporaire), `app/Tests/UI/` (XCUITest — pilote l'app comme utilisateur). Cibles xcodegen : `PinkhaTests`, `PinkhaIntegrationTests`, `PinkhaUITests`. **224 unitaires + 133 d'intégration + XCUITest** (mesuré 2026-08-06).

**Commandes de test** :
```bash
# Rust seul (rapide, sans simulateur) :
cargo test

# Swift complet (tous niveaux, nécessite simulateur booté) :
xcodebuild test -project app/Pinkha.xcodeproj -scheme Pinkha -destination 'id=<UDID>'

# Swift unit + integration seulement (rapide, pas de XCUITest) :
xcodebuild test -project app/Pinkha.xcodeproj -scheme Pinkha -destination 'id=<UDID>' \
    -only-testing:PinkhaTests -only-testing:PinkhaIntegrationTests

# Swift UI seulement :
xcodebuild test -project app/Pinkha.xcodeproj -scheme Pinkha -destination 'id=<UDID>' \
    -only-testing:PinkhaUITests
```

**Launch arguments pour UI tests** (évitent `typeText`, flaky sur simulateur iOS 26) :
- `--ui-test-data` : DB éphémère + 2 docs pré-seedés ("Seeded Note 1", "Seeded Note 2")
- `--ui-test-clean` : DB éphémère vide (pour tester l'état vide)
- **Règle** : toute fonctionnalité doit avoir des tests aux 3 niveaux, pas seulement les features critiques.

## Notes
- `#![allow(dead_code)]` intentionnel pour le code book non encore connecté à l'UI.
- `#[serde(alias = "style")]` sur `InlineText.styles` pour charger les anciens JSON.
- Les mutations de blocs en Swift se font en mémoire d'abord (pas de rechargement SQLite après insert/delete) pour éviter l'effacement du contenu en cours de frappe.
- `fontWithTraits(_:bold:italic:)` utilise `boldSystemFont`/`italicSystemFont` en fallback car `withSymbolicTraits` retourne `nil` sur SF Pro dans certains contextes iOS.
- `NSAttributedString.Key.pinkhaColor` stocke le nom de couleur (String) en parallèle de `.foregroundColor` pour un round-trip `NSAttributedString ↔ [InlineTextFfi]` fiable.

## Dette technique — à reprendre avant scaling / mise en prod sérieuse

Ces points sont **acceptables en l'état actuel** (projet solo, 690+ tests Rust + 357 tests Swift unit/integration) mais devront être traités avant d'ouvrir aux contributeurs / déployer en App Store. Ordre de priorité :

### Infrastructure (haute priorité dès qu'on collabore)
- **CI GitHub Actions** :
  - ✅ Rust : `cargo test` sur push/PR vers master/staging/dev (`macos-15` runner).
  - ✅ Swift : `xcodebuild test` (PinkhaTests + PinkhaIntegrationTests) sur **runner self-hosted** — la machine de dev, qui a Xcode 27 et le simulateur « Pinkha SIM ». Label custom `xcode27` : quand la machine est éteinte, le job expire au timeout (45 min) au lieu de bloquer la PR. Garde anti-fork obligatoire (`head.repo.full_name == github.repository`) — le repo est public avec forks autorisés, sans elle une PR quelconque exécuterait du code arbitraire sur la machine perso. Les XCUITest restent hors CI : ils exigent une session graphique connectée, le runner tourne en LaunchAgent. Setup complet + pièges (PATH launchd, locale, garde anti-fork) : **`utilities/docs/SELF-HOSTED-RUNNER.md`**. Les tests passent par **`app/Pinkha.xctestplan`** (`diagnosticCollectionPolicy: Never`) : sans lui, `xcodebuild` bloque 600 s après chaque run sur la collecte de diagnostics du simulateur — ~615 s contre ~12 s. Ne pas retirer ce réglage sans lire la section dédiée de la doc.
  - ⏸ ~~Swift `xcodebuild test` désactivé temporairement~~ — les runners ont Xcode 16.4 / iOS 18.5 SDK, alors que le projet target iOS 26.0 et utilise `UIGlassEffect` / `.glassEffect()`. À réactiver soit (a) quand Xcode 26 stable arrive sur les runners post-WWDC 2026, soit (b) en backportant avec `if #available(iOS 26.0, *)` + fallback `UIBlurEffect`. Voir `.github/workflows/ci.yml` (job `swift-placeholder`).
- **Branch protection** : `master`, `staging`, `dev` protégées — PR obligatoire, pas de force-push, pas de suppression. Status checks (CI requise pour merge) à ajouter quand la CI Swift sera réactivée.
- **Code coverage** : Rust gaté à **89% de lignes** en CI (ratchet — on ne descend plus ; tightening progressif vers 95/98% prévu) via `cargo llvm-cov --workspace --fail-under-lines 89 --summary-only` avec exclusions sur les paths intestables unitairement (entry points, Notion HTTP, extractors Craft/Bear nécessitant fixtures externes). Couverture mesurée 2026-06-02 (après vague 1 + reader.rs complet) : **91.40% lines / 88.98% functions / 93.22% regions**. Tests :
  - 90 dans `tests/integration_ffi.rs` (PinkhaApi : docs, blocs, books, properties, views, queries, shelves, validation)
  - 20 dans `tests/integration_shelf_store.rs` (CRUD/move/delete shelf store)
  - in-module `src/domain/shelf.rs`
  - 26 dans `crates/realm-codec/tests/reader_new_format.rs` — bytes new-format cluster-tree construits à la main pour exercer `read_table_new` / `collect_strings_new` (3 variantes leaf : inline-multiply, compact-string, per-row refs) / `collect_ints_new` / `collect_linklists_new` / `cluster_index_for_col` (Timestamp 2-slots + BackLink 0-slot après fix du bug code 13/14) + paths défensifs. `reader.rs` passé de **31.48% → 79.44%**. Reste 20% non couverts = old-format B-tree (`read_cell_btree`, `count_node_rows` inner), probablement code mort en prod Craft cluster-tree.
  - Pour atteindre 98% : ~934 lignes restantes (ffi.rs imports HTTP non-mockables, retry paths SQLite, use_cases/blocks + book_leaf_sync, book_use_cases/query).
  - Swift : `xcodebuild -enableCodeCoverage YES` à mesurer quand le job Swift sera réactivé.
- **Workflow contributeur** : ✅ branches `feature/**`, `fix/**`, `refactor/**`, `docs/**`, `chore/**`, `perf/**` depuis `dev` ; promotion `dev` → `staging` → `master`. Cf. section "Git workflow" plus haut.
- **Pre-commit hook** : ✅ `utilities/scripts/hooks/pre-commit` versionné, installé via `./utilities/scripts/install-hooks.sh` (symlinks dans `.git/hooks/`). Tourne `cargo fmt --all --check` + `cargo clippy --workspace --all-targets -- -D warnings` quand au moins un fichier `.rs` est staged. Skip silencieux pour les commits docs/Swift-only. Bypass d'urgence via `git commit --no-verify` mais la règle reste : corriger plutôt que skip.
- **Clippy strict dans la CI** : ✅ `cargo clippy --workspace --all-targets -- -D warnings` est lancé avant les tests dans `.github/workflows/ci.yml` (job `rust`). Mirror du hook pre-commit — toute modification doit être appliquée aux deux gates pour rester synchronisés.

### Tests à renforcer
- **Coordinator class** (`RichTextEditor.Coordinator`) : selection memory (`rememberSelection`/`selectionForToolbar`), toolbar state updates (`updateToolbar`), color application chain — tout n'est testé qu'**en bout-en-bout** via le VM. Un bug subtil dans cette logique passerait. Extraire en helpers libres ou exposer pour tests.
- **`integration_retry.rs`** : prouve que les ops concurrentes ne cassent pas, **pas** que le retry se déclenche vraiment (test passe en 0.16s, scheduler n'a probablement pas créé de contention). Pour valider l'activation : ajouter point d'injection (mock connection avec `busy_timeout=0` + lock forcé) qui force un retry attendu.
- **`ActionRepeater` async test** : utilise `Task.sleep(220ms)` puis vérifie `≥3 ticks`. Flaky-prone sous CI chargée. Remplacer par mock timer (interface `Timer`-like injectable).
- **Book FFI** : 13 tests sur une surface énorme. Manque : `queryWithRollups` avec vrais Relation + Aggregate (j'ai juste testé que DB vide retourne `[]`), filters complexes (`Equal`/`Contains` avec valeurs typées), `groupedQuery` avec données, `MultiSelect`/`Relation`/`Date` round-trip JSON.
- **Markdown shortcuts E2E** : `markdownShortcut(for:)` helper unit-testé, mais le déclenchement effectif via `textViewDidChange` jamais validé end-to-end (faut taper "# " puis vérifier conversion).
- **`errorAlert` SwiftUI** : modificateur testé indirectement via les helpers Resilience, jamais visuellement. Ajouter snapshot testing (`swift-snapshot-testing`) pour les composants UI critiques.

### Limitations connues à résoudre
- **`typeText` flaky sur simulateur iOS 26** : bypass actuel via launch args `--ui-test-data`/`--ui-test-clean`. **Blocage** : impossible de tester E2E les flows demandant vraie saisie utilisateur (édition de titre dans la sheet de création, recherche). Pistes : `UIPasteboard` + long-press + Coller, `app.keys["X"].tap()` sur le clavier software, custom URL scheme pour pré-remplir.
- ~~**`xcframework` métadonnées trackées**~~ ✅ résolu mai 2026 : tout `pinkha.xcframework/` est désormais gitignored, reconstruit via `./build-xcframework.sh`.
- **OAuth Notion — custom URL scheme `pinkha://`** : le flow utilise un scheme custom déclaré dans `Info.plist` (`CFBundleURLSchemes = ["pinkha"]`) comme dernier saut du redirect (proxy → app). C'est exploitable en théorie : iOS ne valide pas l'unicité des custom schemes, une app malveillante installée après pinkha pourrait revendiquer `pinkha://` et intercepter le `code` Notion lors d'un consent. **Mitigation actuelle** : (a) `ASWebAuthenticationSession` ne livre le scheme qu'à l'app qui a démarré la session (pas un universel `openURL`), (b) le `code` Notion est single-use et expire en 10 min, (c) l'attaquant devrait persuader l'utilisateur d'installer son app *avant* de tenter un import. Risque résiduel faible mais réel. **Solution propre** : migrer vers **Universal Links** quand un domaine perso sera dispo : (a) acheter un domaine (ex. `pinkha.app`), (b) servir `https://pinkha.app/.well-known/apple-app-site-association` qui prouve l'association app↔domaine, (c) ajouter l'entitlement `applinks:pinkha.app` dans xcodegen, (d) remplacer `redirectUri` et `callbackScheme` par l'URL HTTPS du domaine. Le scheme `pinkha://` et le bridge `/oauth/callback` du proxy peuvent alors disparaître.
- **`realm-codec/src/reader.rs` à 79.44%** : les 20% restants sont uniquement du code **old-format B-tree inner node** (`count_node_rows` avec `is_inner = true`, `read_cell_btree`) qui n'est probablement jamais exercé en prod — Craft est 100% cluster-tree (SDK 5+), donc ces chemins sont **probablement morts**. Candidat à la suppression plutôt qu'aux tests si une revue confirme qu'aucun fichier `.realm` réel ne déclenche `read_cell_btree`. Bug BackLink **corrigé 2026-06-02** : `cluster_index_for_col` traitait à tort le nibble code 13 (LinkList) comme zero-slot ; corrigé en code 14 (BackLink) conformément au format Realm SDK 5+ et au mapping `ColumnType::from_u8`. Toutes les 3 variantes de string leaf désormais testées (inline-multiply, compact-string `[offsets_ref, blob_ref]`, per-row refs vers wtype=2 nodes).

### Features prioritaires (par valeur perçue)
1. **UI Books** — backend full testé, manque juste les vues SwiftUI. Énorme impact, faisabilité élevée (réutiliser `BlockTextEditor`/`BlockCallbacks` patterns).
2. **Barre de recherche** — `searchLeaves`/`searchInBlocks` FFI testés, faut une UI au-dessus (TextField + List filtrée). Quick win.
3. **iPad / Mac NavigationSplitView** — élargit drastiquement le public, faisabilité moyenne (gestion adaptive layout).
4. **Sync CRDT entre appareils** — gros morceau, à faire après les 3 du dessus. `updated_at` et soft delete déjà en place côté Rust.

### Pour chaque nouvelle feature, exige (règle non négociable)
- 1 test unitaire sur la logique pure (si y'en a)
- 1 test d'intégration sur le flow FFI / VM
- 1 test UI E2E si c'est interactif (avec launch args seeded si saisie nécessaire)

Cette discipline maintient la pyramide vivante sans CI. Le jour où on ajoute CI, ça force aussi PR-by-PR.
