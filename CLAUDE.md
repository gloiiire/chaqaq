# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Vision

**pinkha** — app de notes personnelle, mélange Craft (beauté, fluidité, rendu natif) + Notion (databases, structure). Full Rust pour le core. Objectif : publication open source, car un rich text editor en Rust n'existe pas encore dans l'écosystème.

Plateformes cibles : iPhone, iPad, Mac. Décision UI : **SwiftUI + UniFFI** — rendu 100 % natif (iOS 26, scroll physics natif, tab bar native), Rust pour le core.

## Commands

```bash
cargo run     # alias: r
cargo build   # alias: cb
cargo check   # alias: cc
cargo test

# Tester uniquement le crate chaqaq
cargo test -p chaqaq

# Régénérer les bindings Swift après modification du .udl ou de ffi.rs
cargo build
cargo run --bin uniffi-bindgen -- generate --library target/debug/libpinkha.dylib \
    --language swift --out-dir swift-bindings/

# Publier une nouvelle version de chaqaq sur crates.io
# (bumper la version dans crates/chaqaq/Cargo.toml d'abord)
cd crates/chaqaq && cargo publish
```

## Architecture (Clean Architecture)

Le repo est un **Cargo workspace** avec trois crates :
- `crates/chaqaq` — crate autonome open source publié sur crates.io (MIT OR Apache-2.0)
- `crates/realm-codec` — parser/writer Realm v9 binary, publié sur crates.io (MIT OR Apache-2.0)
- `.` (pinkha) — application complète, dépend de chaqaq via `{ path = "crates/chaqaq" }`

```
crates/chaqaq/     — crate autonome rich text editor (crates.io: chaqaq v0.1.0)
crates/realm-codec/ — parser/writer Realm v9 binary (crates.io: realm-codec v0.1.0)
  src/
    lib.rs     — RealmFile, RealmTable, Row, Value, ColumnType, RealmError
    format.rs  — NodeHeader, decode_short_string, read_bits_elem (pub(crate))
    reader.rs  — B-tree traversal, read_tables
    write.rs   — RealmBuilder, TableBuilder (sérialisation bottom-up)

crates/chaqaq/     — crate autonome rich text editor (crates.io: chaqaq v0.1.0)
  src/
    lib.rs         — API publique + doc crate
    document.rs    — InlineStyle, InlineText
    rich_text.rs   — RichText + Span (indices chars Unicode)
    editor.rs      — EditorState (curseur, sélection, toggle style)
    commands.rs    — Command trait + Insert, Delete, ApplyStyle, History
    parser.rs      — parse_inline() (state machine markdown)

src/
  domain/          — re-exports depuis chaqaq + types pinkha-spécifiques
    document.rs    — re-exporte InlineStyle/InlineText + Block, Document, DocumentMeta
    parser.rs      — re-exporte parse_inline
    rich_text.rs   — re-exporte RichText, Span
    editor.rs      — re-exporte EditorState
    commandes.rs   — re-exporte Command, Insert, Delete, ApplyStyle, History
    database.rs    — types Database/Notion (Property, Entry, View, Filter, Sort…)
  application/     — traits + use cases
    repository.rs  — trait DocumentRepository (save, load, list, delete)
    use_cases.rs   — use cases documents et blocs
    database_repository.rs — trait DatabaseRepository
    database_use_cases.rs  — use cases database
    error.rs       — PinkhaError (NonTrouve, OperationInvalide, Io, Json, Db)
  infrastructure/
    migrations.rs            — migrations SQLite versionnées (rusqlite_migration)
    sqlite_document_store.rs — SqliteDocumentStore : stockage local-first recommandé
    sqlite_database_store.rs — SqliteDatabaseStore : stockage local-first recommandé
    json_store.rs            — JsonStore : conservé pour les tests et le proto
    database_store.rs        — DatabaseStore JSON : conservé pour les tests
  extractors/      — pipelines d'import, un par source (Notion, Bear, …)
    mod.rs         — ExtractorError, ImportResult
    traits.rs      — trait Extractor (async run, Config associé)
    notion/        — client reqwest + serde types + mapper + pipeline paginé
      client.rs    — HTTP client (reqwest, rustls-tls, iOS-compatible)
      schema.rs    — types serde pour API Notion v1 (database, pages, blocs)
      mapper.rs    — Notion → domaine Pinkha (propriétés, valeurs, blocs)
      mod.rs       — pipeline complet : schéma → DB → pages → blocs récursifs
    bear/          — lecteur SQLite + parseur Markdown Bear
      reader.rs    — rusqlite read-only, conversion timestamps Core Data
      schema.rs    — BearNote row type
      mapper.rs    — parseur Markdown Bear ligne par ligne
      mod.rs       — importe toutes les notes non supprimées
  ffi.rs           — façade UniFFI : PinkhaApi, PinkhaError FFI, types dictionnaire
  pinkha.udl       — interface UDL déclarant l'API publique Swift/Kotlin
  bin/
    uniffi-bindgen.rs — binaire local pour générer les bindings
  main.rs          — point d'entrée démo
swift-bindings/    — bindings Swift générés (pinkha.swift, pinkhaFFI.h, .modulemap)
pinkha.xcframework — XCFramework compilé (ios-arm64, ios-arm64-simulator, macos-arm64)
build-xcframework.sh — script de compilation du XCFramework
app/               — application SwiftUI (projet Xcode généré par xcodegen)
  project.yml      — config xcodegen
  Pinkha.xcodeproj/
  Sources/
    PinkhaApp.swift      — point d'entrée @main
    ContentView.swift    — TabView 3 onglets (Notes/Bases/Recherche) + PinkhaStore
    DocumentView.swift   — éditeur de document + DocumentViewModel
    Models.swift         — miroirs Swift des types Rust (Codable)
    RichTextEditor.swift — UIViewRepresentable + toolbar de formatage
```

Règle de dépendance : `infrastructure` → `application` → `domain`. Le domaine ne sait rien du stockage.

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

### `domain/document.rs`
Re-exporte `InlineStyle` et `InlineText` depuis chaqaq. Définit les types pinkha-spécifiques :
- `BlockContent` : Text, Heading { level, text }, Quote { icon, text }, Todo { done, text }, Divider, Breadcrumb, Database { id }
- `Block { id: Uuid, content: BlockContent, children: Vec<Block> }` — nœud récursif
- `Document { id, cover, title: Vec<InlineText>, blocks: Vec<Block> }`
- `DocumentMeta { id, cover, title, updated_at }` — vue légère sans blocks pour `list()`. `updated_at` peuplé par SQLite, vide sinon (`#[serde(default)]`)

### `domain/parser.rs` / `rich_text.rs` / `editor.rs` / `commandes.rs`
Simples re-exports depuis `chaqaq` — aucune logique propre.

### `domain/database.rs`
Moteur type Notion (défini dans pinkha, pas dans chaqaq) :
- `PropertyType` : Title, Text, Number, Selection, SelectionMultiple, Date, Checkbox, Url, Relation, Rollup
- `PropertyValue` : valeurs correspondantes + `Empty`
- `Entry { id, created_at: String (ISO 8601), values: HashMap<Uuid, PropertyValue> }`
- `ViewType` : Table, Kanban { group_by }, Calendar { property_id }, Gallery
- `Filter { property_id, condition: FilterCondition }`, `Sort { property_id, order, source: SortSource }`
- `SortSource` : Property | Creation | ManualThenCreation (pour journaux mixtes)
- `Database { id, title, properties, entries, views }`, `DatabaseMeta { id, title, updated_at }`

### `application/error.rs`
`PinkhaError` : `NotFound(Uuid)`, `InvalidOperation(String)`, `Io(std::io::Error)`, `Json(serde_json::Error)`, `Db(String)`
— `Db(String)` convertit les erreurs rusqlite en string pour ne pas coupler l'application à SQLite.
— implémente `std::error::Error` + `From<io::Error>` + `From<serde_json::Error>`

### `application/use_cases.rs`
- `create_document`, `get_document`, `list_documents`, `delete_document`
- `update_document_title`, `update_document_cover`
- `add_block`, `update_block`, `delete_block`
- `reorder_blocks(doc_id, order)` — réordonne les blocs racine
- `reorder_child_blocks(doc_id, parent_id, order)` — réordonne les enfants d'un bloc
- `add_child_block(doc_id, parent_id, content)` — imbrique un bloc
- `move_block(doc_id, block_id, new_parent_id: Option<Uuid>)` — déplace vers un parent (None = racine)
- `save_edited_block(doc_id, block_id, &EditorState)` — bridge éditeur → persistance
- `search_documents(query)` — insensible à la casse dans les titres
- `search_in_blocks(query)` — plein texte dans le contenu des blocs (récursif)

### `application/database_use_cases.rs`
- `create_database`, `get_database`, `list_databases`, `delete_database`
- `add_entry`, `update_entry`, `delete_entry`
- `add_property`, `rename_property`, `delete_property` (nettoie les valeurs dans les entrées)
- `add_view`, `update_view(view_id, filters, sorts)`, `delete_view` (bloque sur la dernière)
- `query(db_id, view_id)` — filtres + tris
- `query_with_rollups` — requête + rollups calculés à la lecture
- `column_aggregate(db_id, prop_id, aggregate)`
- `grouped_query(db_id, view_id, group_by)`
- `search_entries(db_id, query)` — insensible à la casse dans toutes les valeurs textuelles
- `evaluate_rollups(db, entries)` — calcul des colonnes Rollup (non persisté)

### `infrastructure/migrations.rs`
Migrations versionnées via `rusqlite_migration`. Deux fonctions : `apply_document_migrations` et `apply_database_migrations`. Chaque évolution de schéma = un `M::up()` de plus.

### `infrastructure/sqlite_document_store.rs` + `sqlite_database_store.rs`
Stockage SQLite local-first. Schéma : document-as-JSON dans une colonne `data`, avec colonnes indexées (`title_text`, `title_json`, `cover`) pour `list()` rapide sans désérialiser les blocs.
- `updated_at` géré automatiquement à chaque `save()` — prêt pour sync future
- Soft delete : `delete()` pose `deleted_at` au lieu de supprimer — données récupérables pour CRDT
- SQLite bundlé (`features = ["bundled"]`) — pas de dépendance système, fonctionne sur iOS/Android/macOS
- `PRAGMA journal_mode=WAL` activé pour de meilleures performances concurrentes
- Constructeur `in_memory()` pour les tests

### `infrastructure/json_store.rs`
`JsonStore { dir: PathBuf }` — conservé pour compatibilité et tests existants.
`#[serde(alias = "style")]` sur `styles` pour la compat avec les anciens fichiers.

### `ffi.rs` + `pinkha.udl` — Couche UniFFI
Façade publique exposée à Swift via UniFFI 0.31.
- `PinkhaError` FFI : enum `NonTrouve { id }`, `OperationInvalide { detail }`, `Stockage { detail }` — devient un `enum` Swift natif
- `DocumentMetaFfi` / `DatabaseMetaFfi` : structs dictionnaire (id, title_plain, title_json, cover, updated_at, created_at)
- `PinkhaApi` : ouvre les deux stores SQLite au même chemin, expose toutes les opérations documents et databases
- Les blocs et databases complètes transitent en JSON (String) pour éviter le type récursif `Block` dans l'UDL — Swift décode via `Codable`
- `ajouter_bloc` retourne l'UUID du bloc créé (pas le document entier)
- Shift+Enter géré côté éditeur : `EditorState.inserer('\n')` + `sauvegarder_bloc_edite` — aucun variant `LineBreak` nécessaire dans le modèle

Usage Swift :
```swift
let api = try PinkhaApi(cheminDb: path)
let id  = try api.creerDocument(titre: "Ma note")
let json = try api.obtenirDocumentJson(id: id)  // → Codable
```

### `app/Sources/` — Couche UI SwiftUI

**`Models.swift`** — miroirs Swift des types Rust sérialisés par serde :
- `DocumentFfi`, `BlockFfi`, `InlineTextFfi`, `InlineStyleFfi`, `BlockContentFfi` — tous `Codable`
- `InlineStyleFfi` / `BlockContentFfi` : enums avec `init(from:)` / `encode(to:)` custom pour le format externally-tagged de serde
- Helpers sur `BlockContentFfi` : `texteSimple`, `spansOuVide`, `estTodo`, `doneTodo`, `avecTexte`, `avecSpans`, `toAttributedString`

**`RichTextEditor.swift`** — éditeur de texte riche :
- `ExpandingTextView : UITextView` — hauteur automatique via `intrinsicContentSize`, hooks pour Shift+Enter et toggles bold/italic/underline (clavier hardware)
- `RichTextEditor : UIViewRepresentable` — bindings `spans` / `isFocused`, callbacks `onSave`, `onSaveSpans`, `onNewBlock`, `onDeleteBloc`, `onMergeAvecPrecedent`, `onConvert`, `onUndo`/`onRedo` + closures live `canUndoProvider`/`canRedoProvider`
- `spansToAttributed` / `attributedToSpans` — conversion aller-retour avec `.pinkhaColor` custom key pour préserver le nom de couleur
- `NSAttributedString.Key.pinkhaColor` — attribut custom pour stocker le nom de couleur (round-trip fiable)
- `MenuButton : UIButton` — surcharge `contextMenuInteraction(_:willEndFor:)` pour détecter la fermeture des menus déroulants (hide-on-menu façon Notes.app)
- Toolbar pill (style Notes.app) — `UIView` custom avec `UIVisualEffectView(UIGlassEffect())`, `UIScrollView` horizontal, ordre : Coller / Aa (B/I/U/S via menu déroulant) / Highlighter (palette via menu) / Undo / Redo / Return / Dismiss clavier
- Hide-on-menu : ouverture d'un menu déroulant via `UIDeferredMenuElement.uncached` qui cache la pill ; `MenuButton.onMenuWillEnd` la restaure à la fermeture (couvre dismiss par tap dehors)
- `fontWithTraits(_:bold:italic:)` — gras/italique avec fallback `boldSystemFont`/`italicSystemFont` (SF Pro ne propage pas toujours `withSymbolicTraits`)
- `markdownShortcut(for:)` (free function, testable) : `# ` → H1, `## ` → H2, `### ` → H3, `> ` → Quote, `!! ` → Callout, `[ ] ` → Todo, `---` → Divider
- Optim : `lastSyncedSpans` par Coordinator — skip la recomputation de `spansToAttributed` quand un autre bloc reçoit la frappe (SwiftUI re-render global mais ce bloc n'a pas changé)
- Optim : `lastCanUndo`/`lastCanRedo` — évite la recréation d'`UIImage` à chaque keystroke pour les boutons undo/redo de la toolbar
- `toolbarLineBreak()` : insère un `\n` via `tv.insertText` + reset défensif `shiftEnterTyped = false` après (insertText programmé peut bypass `shouldChangeTextIn`)
- `textViewDidChange` appelle `save()` à chaque frappe → capture du burst undo côté VM. Le persist SQLite est différé au flush du burst (1 write par burst, pas par caractère)

**`ContentView.swift`** — racine 3 onglets + store :
- `PinkhaStore : ObservableObject` — `PinkhaApi`, CRUD documents, `search(query:)` → `api.searchDocuments`
- `ContentView` = `TabView { Tab("Notes") Tab("Bases") Tab("Recherche") }` iOS 26
- `NotesHomeView` : salutation, strip horizontale `RecentStrip` (5 derniers docs, `RecentCard` 150×140 pt), `List` sections avec swipe-to-delete, FAB `square.and.pencil`
- `DatabasesHomeView` : placeholder (backend complet, UI à venir)
- `SearchView` : `.searchable` SwiftUI + résultats temps réel via `store.search(query:)`
- `SectionHeader` : label uppercase `.caption.weight(.semibold)` avec kerning

**`DocumentView.swift`** — éditeur de document :
- `EditableBlock : Identifiable, Equatable` — modèle en mémoire : `id`, `content: BlockContentFfi`, `spans: [InlineTextFfi]`, `done: Bool`
- `DocumentViewModel : ObservableObject, @MainActor` — `load`, `saveBlock` / `saveBlock(id:spans:)` (burst), `persistBlock` (mutations structurelles), `addBlock`, `deleteBlock` / `deleteBlocks(ids:)`, `moveBlock`, `applyBlockOrder`, `toggleBlockDone`, `updateBlockIcon`, `convertBlockContent`, `saveTitle`, `saveCover`
- Mutations en mémoire directe (pas de rechargement depuis SQLite après insert/delete — évite l'effacement du contenu en cours d'édition)
- Blocs supportés : Text, Heading (1/2/3), Quote, Callout (Quote avec icône emoji), Todo, Divider
- `ForEach($vm.blocks) { $block in }` — two-way binding pour l'édition en place
- Drag & drop natif via `.onMove` + `EditMode`
- Swipe-to-delete + menu contextuel
- `.scrollDismissesKeyboard(.interactively)` — dismiss clavier par swipe natif
- `autoFocusId` — focus automatique sur le bloc nouvellement créé OU réinséré (undo d'une suppression)

**Undo / redo (Swift) :**
- `UndoManager` natif, `levelsOfUndo = 1000` (aligné sur `CAPACITE_PAR_DEFAUT` du back Rust)
- 2 UI synchronisées : pill glass en bas-gauche (clavier fermé) + boutons dans la toolbar clavier (clavier ouvert)
- `canUndoProvider`/`canRedoProvider` = closures live qui lisent `vm.canUndo`/`vm.canRedo` → toujours frais à chaque updateUIView / textViewDidChange / didChangeSelection
- `vm.canUndo = undoMgr.canUndo || !blockBurstAnchor.isEmpty` — le bouton s'allume aussi quand un burst de typing est pending (l'undo flush d'abord puis annule)
- Toutes les ops VM enregistrent leur inverse : add/delete/move block, toggle todo, change icon, convert content, save title, save cover, frappe
- **Burst undo pour la frappe** (style Notes) : une rafale continue de `saveBlock` sur le même bloc = 1 seule étape undo. `burstInterval = 300 ms` d'inactivité → flush + persist SQLite + register undo. Switch de bloc flush l'ancien immédiatement.
- `BlockSnapshot { content, spans, done }` (Equatable) — état capturé pré-burst (`blockBurstAnchor`) ou stable (`blockSnapshots`)
- `applyBlockSnapshot(blockId:snapshot:)` remplace l'élément entier dans `blocks` (déclenche `@Published` fiablement) + persiste + re-register la reverse
- Observer `NSUndoManagerCheckpoint` async-dispatché pour `objectWillChange.send()` — évite le warning « Publishing changes from within view updates »

**`Resilience.swift`** — UX erreur :
- `PinkhaError.userMessage` (FR), `isRecoverable`, `tryCatch(into: &errorMessage)`, `.errorAlert(message:onRetry:)`

## Roadmap

Ce qui est **fait** — backend Rust + UI SwiftUI :
- Parser inline complet (bold, italic, underline, color, link, combinaisons)
- Types de blocs et documents avec blocs imbriqués récursifs
- `DocumentMeta` pour `list()` sans charger tout le contenu
- Erreurs custom `PinkhaError` (plus de `Box<dyn Error>`)
- `RichText` + `EditorState` : édition en mémoire (curseur, sélection, toggle style)
- Undo/redo via pattern Command côté Rust (`Historique` avec capacité configurable)
- Moteur database type Notion (propriétés, entrées, vues, filtres, tris, rollup, relation)
- CRUD complet blocs : ajouter, modifier, supprimer, réordonner (racine et enfants), imbriquer, déplacer
- Recherche documents par titre + plein texte dans les blocs
- Recherche dans les entrées de database
- Gestion complète des propriétés (ajout, renommage, suppression)
- Gestion complète des vues (ajout, modification filtres/tris, suppression)
- **SQLite local-first** : `SqliteDocumentStore` + `SqliteDatabaseStore` avec soft delete, `updated_at`, migrations versionnées, WAL, retry exponentiel
- **Crate `chaqaq` v0.1.0** : core rich text editor extrait en crate autonome, publié sur crates.io (MIT OR Apache-2.0). Cargo workspace.
- **Crate `realm-codec` v0.1.0** : parser + writer Realm v9 binary (NodeHeader, Group, B-tree, cluster tree format Realm SDK 5+, `RealmBuilder`/`TableBuilder`), publié sur crates.io (MIT OR Apache-2.0). Utilisé par l'extractor Craft.
- **Couche FFI UniFFI** : `PinkhaApi` exposée à Swift en API anglaise idiomatique
- **XCFramework** : `pinkha.xcframework` compilé (ios-arm64, ios-arm64-simulator, macos-arm64)
- **Projet Xcode** : `app/Pinkha.xcodeproj` généré par xcodegen
- **UI SwiftUI** :
  - **Tab bar 3 onglets** (iOS 26 `TabView` + `Tab`) : Notes | Bases | Recherche
  - **Notes** : salutation dynamique, strip horizontale "Récents" (5 derniers docs, cards Apple Music style), liste complète avec swipe-to-delete, FAB `square.and.pencil`
  - **Bases** : placeholder (backend Notion complet côté Rust, UI à venir)
  - **Recherche** : `searchable` SwiftUI + `api.searchDocuments(query:)` FFI, résultats en temps réel
  - Éditeur de document : blocs Text, Heading (×3), Quote, Callout (Quote + emoji), Todo, Divider
  - Texte riche : gras, italique, souligné, barré, 9 couleurs (rouge, rose, orange, jaune, vert, cyan, bleu, violet, marron)
  - Toolbar pill (style Notes.app) glass effect : Coller / Aa (B/I/U/S) / Highlighter / Undo / Redo / Return / Dismiss — hide-on-menu façon Notes
  - Raccourcis markdown : `# `, `## `, `### `, `> `, `!! ` (callout), `[ ] `, `---`
  - Enter → nouveau bloc, Shift+Enter / Return toolbar → saut de ligne dans le bloc, drag & drop, swipe-to-delete, dismiss clavier par swipe
  - Focus automatique sur le bloc créé OU réinséré via undo
  - Undo/redo unifié (1000 niveaux) : pill bas-gauche + boutons toolbar, burst typing 300 ms style Notes, focus auto sur block réinséré
  - Perf : persist SQLite différé au flush burst, cache spans par bloc, cache état boutons undo
- **CI** : GitHub Actions `cargo test` sur push/PR vers master/staging/dev (`macos-15`). Swift job suspendu en attendant Xcode 26 sur les runners
- **Sécurité repo** : branches protégées (PR obligatoire, force-push bloqué, suppression bloquée, Rust CI requise), Secret Scanning + Push Protection, Dependabot Alerts + Security Updates, Dependabot config mensuelle pour Cargo + Actions, job CI `cargo-audit --deny warnings` (scan CVE à chaque PR)
- **Stockage secrets** : `Keychain.swift` (wrapper minimal `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, jamais synchronisé iCloud) pour les tokens d'API. Token Notion persisté après import réussi seulement. OAuth2 client secret JAMAIS embarqué dans le binaire iOS — `NotionOAuth2.tokenProxyUrl` pointe vers un backend proxy qui détient le secret.
- **Architecture OAuth2 Notion** (multi-tenant) — modèle "1 paire de credentials d'app, N tokens utilisateurs" :
  - Credentials de l'app (`NOTION_CLIENT_ID` + `NOTION_CLIENT_SECRET`) = identifient l'app pinkha auprès de Notion. **Une seule paire pour toute l'app, jamais dans le binaire iOS, jamais dans le repo.** Vit uniquement dans les env vars Railway du proxy (et dans `notion-proxy/.env` gitignored en local).
  - Access token utilisateur = scoped à un workspace Notion donné. Généré au runtime via le flow authorization-code, retourné par le proxy à l'app, stocké dans le Keychain iOS (par-device, jamais sync iCloud).
  - Flow concret par user (Alice ouvre l'app distribuée App Store) : (1) `ASWebAuthenticationSession` ouvre `api.notion.com/v1/oauth/authorize?client_id=...` (2) Alice login avec son compte Notion → consent screen "Authorize pinkha?" (3) Notion redirige `pinkha://oauth/notion?code=...` (4) app POST `code` au proxy avec HMAC (5) proxy combine `code` + `client_secret` → `api.notion.com/v1/oauth/token` (6) Notion retourne un `access_token` propre à Alice (7) proxy renvoie le token, app le persiste en Keychain.
  - Bob fait pareil → token distinct. Les users n'ont jamais à connaître les credentials de l'app.
  - **Setup release App Store** : créer une Notion integration **Public** (pas Internal), ajouter `pinkha://oauth/notion` comme redirect URI, configurer les 4 env vars (`NOTION_CLIENT_ID`/`SECRET`, `PROXY_HMAC_SECRET`, `SENTRY_DSN`) côté Railway, mettre l'URL Railway dans `NotionOAuth2.tokenProxyUrl`. Tout user public est ensuite supporté sans config additionnelle.
- **Observabilité (Sentry)** : crash reporting + tracing distribué via [sentry-cocoa](https://github.com/getsentry/sentry-cocoa) 8.49+ (SPM).
  - DSN dans `app/Config/Secrets.xcconfig` (gitignored) + `Secrets.xcconfig.example` (template commit), injecté dans `Info.plist` via build setting. `https://` doit être échappé en `https:/$()/` (xcconfig interprète `//` comme commentaire).
  - Wrapper `app/Sources/Core/Observability.swift` — `start()` no-op silencieux quand DSN absent ou placeholder, `capture(_:)` / `capture(message:)` safe pré-init.
  - Init au démarrage dans `PinkhaApp.init()`. Hook `tryCatch(into:)` dans `Resilience.swift` capture les `PinkhaError.Storage` (transient) + toutes les erreurs non-typées. `NotFound` / `InvalidOperation` restent silencieux (états utilisateur attendus, pas des bugs).
  - **Distributed tracing** : `enableAutoPerformanceTracing` propage automatiquement le header `sentry-trace` sur les requêtes URLSession (vers `notion-proxy` notamment). Aucun code custom requis dans `NotionOAuth2.swift`.
  - 2 projets Sentry séparés dans l'org `Pinkha-app` : `apple-ios` (app) + `notion-proxy` (backend). `tracesSampleRate` à 1.0 en debug, 0.2 en release.
- **Pipelines d'extraction** (`src/extractors/`) :
  - Architecture `Extractor` trait (async, `Config` associé, `ImportResult`)
  - **Notion** : client reqwest rustls-tls, API v1 paginée (database schema → pages → blocs récursifs), mapping complet propriétés/valeurs/blocs, `ImportResultFfi` exposé via UniFFI async
  - **Bear** : lecteur SQLite read-only, conversion timestamps Core Data, parseur Markdown Bear ligne par ligne
  - Trois nouveaux variants `BlockContent` : `BulletedListItem`, `NumberedListItem`, `Code` — full-fidelity import, rendu read-only + édition dans l'éditeur
  - **Craft** : lecteur Realm v9 binary read-only via `realm-codec` (crate workspace), heuristique `rawProperties.titleEnabled == "true"` pour détecter les pages, 2498 docs / 4224 blocs / 41 skipped sur fichier réel
  - `NotionImportView.swift` (thin FFI wrapper) + `BearImportView.swift` (fileImporter) + `CraftImportView.swift` (fileImporter `.realm`) + `NotionOAuth2.swift` (ASWebAuthenticationSession)
  - FAB menu : "Import from Notion" + "Import from Bear" + "Import from Craft"

Ce qui **reste** à construire :
1. UI Databases — tab "Bases" est un placeholder, backend Notion complet existe
2. Vue iPad / Mac (NavigationSplitView)
3. Sync entre appareils (CRDT — s'inspirer de y-octo) — `updated_at` et soft delete déjà en place
4. Réactiver Swift CI quand Xcode 26 sera dispo sur les runners GitHub Actions

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

### Règle Rust-first (non négociable)

**Toute opération sur les données appartient à Rust, jamais à Swift.**

Avant d'écrire un loop ou une logique de traitement en Swift, s'arrêter et implémenter dans Rust :
1. Ajouter la méthode dans `ffi.rs` (suivre le pattern `delete_all_documents` comme référence)
2. L'exposer dans `pinkha.udl` (`[Throws=PinkhaError]`)
3. Rebuilder le XCFramework (`./build-xcframework.sh`)
4. Appeler le FFI depuis Swift

**Opérations qui doivent être dans Rust :**
- Mutations bulk (`delete_all_documents`, `delete_all_databases`, etc.)
- Requêtes filtrées / recherches / agrégations
- Toute logique qui touche au store SQLite

**Exceptions acceptables en Swift (UI layer uniquement) :**
- Formatage pour l'affichage (dates, nombres)
- Wrapping en enum Swift (`WorkspaceItem.note($0)`, `WorkspaceItem.database($0)`)
- `.map(\.id)` pour construire les tableaux d'UUIDs passés aux appels FFI
- Filtres de présentation sur des données déjà fetchées (ex: filtrer les propriétés système de la UI table view)

### Architecture — SOLID + Clean Architecture
- **Single Responsibility** : chaque module/type fait une chose. Domain (types purs), application (use cases + traits), infrastructure (stockage), ffi (adaptateur). Pas de "God objects".
- **Open/Closed** : ajout d'une fonctionnalité = nouveau type/impl, pas de modification des use cases. Les `match` exhaustifs forcent par le compilateur à traiter chaque variant ajouté (voulu).
- **Liskov** : toute impl de `DocumentRepository`/`DatabaseRepository` doit être strictement substituable (les tests tournent sur `MockRepo`, la prod sur `SqliteDocumentStore`).
- **Interface Segregation** : un trait = un rôle. `DocumentRepository` et `DatabaseRepository` sont séparés ; un client documents ne dépend pas des méthodes database.
- **Dependency Inversion** : les use cases dépendent d'abstractions (`&dyn DocumentRepository`), jamais de stores concrets. Seul `ffi.rs` (composition root) connaît les implémentations concrètes (`SqliteDocumentStore`).

### Résilience (back + front)
- **Erreurs typées, pas de panic** : `Result<T, PinkhaError>` côté Rust, throws/Result côté Swift. Jamais de `unwrap()`/`!` en production.
- **Conversion d'erreurs aux frontières** : `From<E>` Rust (cf. `From<CoreError> for PinkhaError` FFI) ; mapping en `PinkhaError` côté Swift via `do/catch` qui remonte un `errorMessage: String?` au store.
- **Pas de couplage à l'impl** : `PinkhaError::Db(String)` convertit les erreurs `rusqlite` en string pour ne pas coupler l'application à SQLite.
- **Retry avec backoff exponentiel** : `application/resilience.rs::retry_with_backoff` (3 essais, 50ms→500ms doublés) wrappe les opérations SQLite write/read. `is_transient()` ne retente que les erreurs verrou/I/O bloquante, jamais les erreurs métier (`NotFound`, `InvalidOperation`).
- **Validation aux frontières FFI** (`ffi.rs`) :
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
- **Tests à 3 niveaux côté Rust** : unitaires (`#[cfg(test)] mod tests` dans chaque module — y compris `resilience.rs` avec 6 tests), intégration (`tests/integration_*`), E2E (`tests/e2e_*`). 204+ tests.
- **Tests à 3 niveaux côté Swift** : `app/Tests/Unit/` (Swift Testing — `@Suite`/`@Test`/`#expect`, code pur), `app/Tests/Integration/` (Swift ↔ FFI réelle avec DB SQLite temporaire), `app/Tests/UI/` (XCUITest — pilote l'app comme utilisateur). Cibles xcodegen : `PinkhaTests`, `PinkhaIntegrationTests`, `PinkhaUITests`. **186+ tests Swift.**

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
- `#![allow(dead_code)]` intentionnel pour le code database non encore connecté à l'UI.
- `#[serde(alias = "style")]` sur `InlineText.styles` pour charger les anciens JSON.
- Les mutations de blocs en Swift se font en mémoire d'abord (pas de rechargement SQLite après insert/delete) pour éviter l'effacement du contenu en cours de frappe.
- `fontWithTraits(_:bold:italic:)` utilise `boldSystemFont`/`italicSystemFont` en fallback car `withSymbolicTraits` retourne `nil` sur SF Pro dans certains contextes iOS.
- `NSAttributedString.Key.pinkhaColor` stocke le nom de couleur (String) en parallèle de `.foregroundColor` pour un round-trip `NSAttributedString ↔ [InlineTextFfi]` fiable.

## Dette technique — à reprendre avant scaling / mise en prod sérieuse

Ces points sont **acceptables en l'état actuel** (projet solo, 208 tests Rust + 179 tests Swift unit/integration) mais devront être traités avant d'ouvrir aux contributeurs / déployer en App Store. Ordre de priorité :

### Infrastructure (haute priorité dès qu'on collabore)
- **CI GitHub Actions** :
  - ✅ Rust : `cargo test` sur push/PR vers master/staging/dev (`macos-15` runner).
  - ⏸ Swift `xcodebuild test` désactivé temporairement — les runners ont Xcode 16.4 / iOS 18.5 SDK, alors que le projet target iOS 26.0 et utilise `UIGlassEffect` / `.glassEffect()`. À réactiver soit (a) quand Xcode 26 stable arrive sur les runners post-WWDC 2026, soit (b) en backportant avec `if #available(iOS 26.0, *)` + fallback `UIBlurEffect`. Voir `.github/workflows/ci.yml` (job `swift-placeholder`).
- **Branch protection** : `master`, `staging`, `dev` protégées — PR obligatoire, pas de force-push, pas de suppression. Status checks (CI requise pour merge) à ajouter quand la CI Swift sera réactivée.
- **Code coverage** : `xcodebuild -enableCodeCoverage YES` (Swift) + `cargo-llvm-cov` (Rust). On compte les tests mais on ne connaît pas leur couverture réelle (peut être 30% ou 90%).
- **Workflow contributeur** : ✅ branches `feature/**`, `fix/**`, `refactor/**`, `docs/**`, `chore/**`, `perf/**` depuis `dev` ; promotion `dev` → `staging` → `master`. Cf. section "Git workflow" plus haut.

### Tests à renforcer
- **Coordinator class** (`RichTextEditor.Coordinator`) : selection memory (`rememberSelection`/`selectionForToolbar`), toolbar state updates (`updateToolbar`), color application chain — tout n'est testé qu'**en bout-en-bout** via le VM. Un bug subtil dans cette logique passerait. Extraire en helpers libres ou exposer pour tests.
- **`integration_retry.rs`** : prouve que les ops concurrentes ne cassent pas, **pas** que le retry se déclenche vraiment (test passe en 0.16s, scheduler n'a probablement pas créé de contention). Pour valider l'activation : ajouter point d'injection (mock connection avec `busy_timeout=0` + lock forcé) qui force un retry attendu.
- **`ActionRepeater` async test** : utilise `Task.sleep(220ms)` puis vérifie `≥3 ticks`. Flaky-prone sous CI chargée. Remplacer par mock timer (interface `Timer`-like injectable).
- **Database FFI** : 13 tests sur une surface énorme. Manque : `queryWithRollups` avec vrais Relation + Aggregate (j'ai juste testé que DB vide retourne `[]`), filters complexes (`Equal`/`Contains` avec valeurs typées), `groupedQuery` avec données, `MultiSelect`/`Relation`/`Date` round-trip JSON.
- **Markdown shortcuts E2E** : `markdownShortcut(for:)` helper unit-testé, mais le déclenchement effectif via `textViewDidChange` jamais validé end-to-end (faut taper "# " puis vérifier conversion).
- **`errorAlert` SwiftUI** : modificateur testé indirectement via les helpers Resilience, jamais visuellement. Ajouter snapshot testing (`swift-snapshot-testing`) pour les composants UI critiques.

### Limitations connues à résoudre
- **`typeText` flaky sur simulateur iOS 26** : bypass actuel via launch args `--ui-test-data`/`--ui-test-clean`. **Blocage** : impossible de tester E2E les flows demandant vraie saisie utilisateur (édition de titre dans la sheet de création, recherche). Pistes : `UIPasteboard` + long-press + Coller, `app.keys["X"].tap()` sur le clavier software, custom URL scheme pour pré-remplir.
- ~~**`xcframework` métadonnées trackées**~~ ✅ résolu mai 2026 : tout `pinkha.xcframework/` est désormais gitignored, reconstruit via `./build-xcframework.sh`.

### Features prioritaires (par valeur perçue)
1. **UI Databases** — backend full testé, manque juste les vues SwiftUI. Énorme impact, faisabilité élevée (réutiliser `BlockTextEditor`/`BlockCallbacks` patterns).
2. **Barre de recherche** — `searchDocuments`/`searchInBlocks` FFI testés, faut une UI au-dessus (TextField + List filtrée). Quick win.
3. **iPad / Mac NavigationSplitView** — élargit drastiquement le public, faisabilité moyenne (gestion adaptive layout).
4. **Sync CRDT entre appareils** — gros morceau, à faire après les 3 du dessus. `updated_at` et soft delete déjà en place côté Rust.

### Pour chaque nouvelle feature, exige (règle non négociable)
- 1 test unitaire sur la logique pure (si y'en a)
- 1 test d'intégration sur le flow FFI / VM
- 1 test UI E2E si c'est interactif (avec launch args seeded si saisie nécessaire)

Cette discipline maintient la pyramide vivante sans CI. Le jour où on ajoute CI, ça force aussi PR-by-PR.
