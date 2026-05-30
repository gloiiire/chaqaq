# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Vision

**chaqaq** — app de notes personnelle, mélange Craft (beauté, fluidité, rendu natif) + Notion (databases, structure). Full Rust pour le core. Objectif : publication open source, car un rich text editor en Rust n'existe pas encore dans l'écosystème.

Plateformes cibles : iPhone, iPad, Mac. Décision UI : **SwiftUI + UniFFI** — rendu 100 % natif (iOS 26, scroll physics natif, tab bar native), Rust pour le core.

## Commands

```bash
cargo run     # alias: r
cargo build   # alias: cb
cargo check   # alias: cc
cargo test

# Régénérer les bindings Swift après modification du .udl ou de ffi.rs
cargo build
cargo run --bin uniffi-bindgen -- generate --library target/debug/libchaqaq.dylib \
    --language swift --out-dir swift-bindings/
```

## Architecture (Clean Architecture)

```
src/
  domain/          — types purs + parser (aucune dépendance externe)
    document.rs    — types de base (InlineStyle, InlineText, Block, Document, DocumentMeta)
    parser.rs      — state machine inline (bold, italic, underline, color, link)
    rich_text.rs   — RichText (string plate + spans) pour l'édition en mémoire
    editor.rs      — EditorState (curseur, sélection, toggle style)
    commandes.rs   — pattern Command : Inserer, Supprimer, AppliquerStyle + Historique (undo/redo)
    database.rs    — types Database/Notion (Propriete, Entree, Vue, Filtre, Tri, Groupe…)
  application/     — traits + use cases
    repository.rs  — trait DocumentRepository (save, load, list, delete)
    use_cases.rs   — use cases documents et blocs
    database_repository.rs — trait DatabaseRepository
    database_use_cases.rs  — use cases database
    error.rs       — ChaqaqError (NonTrouve, OperationInvalide, Io, Json, Db)
  infrastructure/
    migrations.rs            — migrations SQLite versionnées (rusqlite_migration)
    sqlite_document_store.rs — SqliteDocumentStore : stockage local-first recommandé
    sqlite_database_store.rs — SqliteDatabaseStore : stockage local-first recommandé
    json_store.rs            — JsonStore : conservé pour les tests et le proto
    database_store.rs        — DatabaseStore JSON : conservé pour les tests
  ffi.rs           — façade UniFFI : ChaqaqApi, ChaqaqError FFI, types dictionnaire
  chaqaq.udl       — interface UDL déclarant l'API publique Swift/Kotlin
  bin/
    uniffi-bindgen.rs — binaire local pour générer les bindings
  main.rs          — point d'entrée démo
swift-bindings/    — bindings Swift générés (chaqaq.swift, chaqaqFFI.h, .modulemap)
chaqaq.xcframework — XCFramework compilé (ios-arm64, ios-arm64-simulator, macos-arm64)
build-xcframework.sh — script de compilation du XCFramework
app/               — application SwiftUI (projet Xcode généré par xcodegen)
  project.yml      — config xcodegen
  Chaqaq.xcodeproj/
  Sources/
    ChaqaqApp.swift      — point d'entrée @main
    ContentView.swift    — écran d'accueil + ChaqaqStore
    DocumentView.swift   — éditeur de document + DocumentViewModel
    Models.swift         — miroirs Swift des types Rust (Codable)
    RichTextEditor.swift — UIViewRepresentable + toolbar de formatage
```

Règle de dépendance : `infrastructure` → `application` → `domain`. Le domaine ne sait rien du stockage.

### `domain/document.rs`
- `InlineStyle` : Bold, Italic, Underline, Color(String), Link(String)
- `InlineText { content: String, styles: Vec<InlineStyle> }` — feuille de tout texte riche
- `BlockContent` : Text, Heading { level, text }, Quote { icon, text }, Todo { done, text }, Divider, Breadcrumb, Database { id }
- `Block { id: Uuid, content: BlockContent, children: Vec<Block> }` — nœud récursif
- `Document { id, cover, title: Vec<InlineText>, blocks: Vec<Block> }`
- `DocumentMeta { id, cover, title, updated_at }` — vue légère sans blocks pour `list()`. `updated_at` peuplé par SQLite, vide sinon (`#[serde(default)]`)

### `domain/parser.rs`
State machine sur `chars().peekable()`. `flush()` vide `current_text` dans le résultat avec les styles actifs.
- `**gras**` → Bold
- `_italique_` → Italic
- `__souligné__` → Underline
- `{rouge:texte}` → Color("rouge")
- `[texte](url)` → Link(url)
- Combinaisons : `**_gras+italique_**` ✓

### `domain/rich_text.rs`
`RichText` : représentation d'édition (string plate de chars + `Vec<Span>`). Indices char Unicode, pas bytes.
- `inserer_char` / `supprimer_char` — décale les spans automatiquement
- `toggler_style(range, style)` — ajoute si absent sur au moins un char, retire si tous l'ont
- Conversion `From<&Vec<InlineText>>` et `From<&RichText> for Vec<InlineText>` (aller-retour persistance)

### `domain/editor.rs`
`EditorState { texte: RichText, curseur: usize, selection: Option<Range<usize>> }`
- `inserer`, `supprimer_avant`, `supprimer_apres`
- `deplacer_gauche/droite`, `aller_au_debut/fin`
- `selectionner(range)`, `toggler_style(style)`

### `domain/commandes.rs`
Pattern Command pour undo/redo :
- `Inserer`, `Supprimer`, `AppliquerStyle` — chacun implémente `Commande { executer, annuler }`
- `Historique { fait, annule, capacite }` — `appliquer`, `annuler`, `refaire`, limite configurable

### `domain/database.rs`
Moteur type Notion :
- `ProprieteType` : Titre, Texte, Nombre, Selection, SelectionMultiple, Date, Case, Url, Relation, Rollup
- `ValeurPropriete` : valeurs correspondantes + `Vide`
- `Entree { id, cree_le: String (ISO 8601), valeurs: HashMap<Uuid, ValeurPropriete> }`
- `TypeVue` : Tableau, Kanban { grouper_par }, Calendrier { propriete_id }, Galerie
- `Filtre { propriete_id, condition: ConditionFiltre }`, `Tri { propriete_id, ordre, source: SourceTri }`
- `SourceTri` : Propriete | Creation | ManuellePuisCreation (pour journaux mixtes)
- `Database { id, titre, proprietes, entrees, vues }`, `DatabaseMeta { id, titre, updated_at }`

### `application/error.rs`
`ChaqaqError` : `NonTrouve(Uuid)`, `OperationInvalide(String)`, `Io(std::io::Error)`, `Json(serde_json::Error)`, `Db(String)`
— `Db(String)` convertit les erreurs rusqlite en string pour ne pas coupler l'application à SQLite.
— implémente `std::error::Error` + `From<io::Error>` + `From<serde_json::Error>`

### `application/use_cases.rs`
- `creer_document`, `obtenir_document`, `lister_documents`, `supprimer_document`
- `modifier_titre_document`, `modifier_couverture_document`
- `ajouter_bloc`, `modifier_bloc`, `supprimer_bloc`
- `reordonner_blocs(doc_id, ordre)` — réordonne les blocs racine
- `reordonner_blocs_enfants(doc_id, parent_id, ordre)` — réordonne les enfants d'un bloc
- `ajouter_bloc_enfant(doc_id, parent_id, contenu)` — imbrique un bloc
- `deplacer_bloc(doc_id, block_id, nouveau_parent_id: Option<Uuid>)` — déplace vers un parent (None = racine)
- `sauvegarder_bloc_edite(doc_id, block_id, &EditorState)` — bridge éditeur → persistance
- `rechercher_documents(query)` — insensible à la casse dans les titres
- `rechercher_dans_blocs(query)` — plein texte dans le contenu des blocs (récursif)

### `application/database_use_cases.rs`
- `creer_database`, `obtenir_database`, `lister_databases`, `supprimer_database`
- `ajouter_entree`, `modifier_entree`, `supprimer_entree`
- `ajouter_propriete`, `renommer_propriete`, `supprimer_propriete` (nettoie les valeurs dans les entrées)
- `ajouter_vue`, `modifier_vue(vue_id, filtres, tris)`, `supprimer_vue` (bloque sur la dernière)
- `requete(db_id, vue_id)` — filtres + tris
- `requete_avec_rollups` — requête + rollups calculés à la lecture
- `agregat_colonne(db_id, prop_id, agregat)`
- `requete_groupee(db_id, vue_id, grouper_par)`
- `rechercher_entrees(db_id, query)` — insensible à la casse dans toutes les valeurs textuelles
- `evaluer_rollups(db, entrees)` — calcul des colonnes Rollup (non persisté)

### `infrastructure/migrations.rs`
Migrations versionnées via `rusqlite_migration`. Deux fonctions : `appliquer_migrations_documents` et `appliquer_migrations_databases`. Chaque évolution de schéma = un `M::up()` de plus.

### `infrastructure/sqlite_document_store.rs` + `sqlite_database_store.rs`
Stockage SQLite local-first. Schéma : document-as-JSON dans une colonne `data`, avec colonnes indexées (`title_text`, `title_json`, `cover`) pour `list()` rapide sans désérialiser les blocs.
- `updated_at` géré automatiquement à chaque `save()` — prêt pour sync future
- Soft delete : `delete()` pose `deleted_at` au lieu de supprimer — données récupérables pour CRDT
- SQLite bundlé (`features = ["bundled"]`) — pas de dépendance système, fonctionne sur iOS/Android/macOS
- `PRAGMA journal_mode=WAL` activé pour de meilleures performances concurrentes
- Constructeur `en_memoire()` pour les tests

### `infrastructure/json_store.rs`
`JsonStore { dir: PathBuf }` — conservé pour compatibilité et tests existants.
`#[serde(alias = "style")]` sur `styles` pour la compat avec les anciens fichiers.

### `ffi.rs` + `chaqaq.udl` — Couche UniFFI
Façade publique exposée à Swift via UniFFI 0.31.
- `ChaqaqError` FFI : enum `NonTrouve { id }`, `OperationInvalide { detail }`, `Stockage { detail }` — devient un `enum` Swift natif
- `DocumentMetaFfi` / `DatabaseMetaFfi` : structs dictionnaire (id, title_plain, title_json, cover, updated_at, created_at)
- `ChaqaqApi` : ouvre les deux stores SQLite au même chemin, expose toutes les opérations documents et databases
- Les blocs et databases complètes transitent en JSON (String) pour éviter le type récursif `Block` dans l'UDL — Swift décode via `Codable`
- `ajouter_bloc` retourne l'UUID du bloc créé (pas le document entier)
- Shift+Enter géré côté éditeur : `EditorState.inserer('\n')` + `sauvegarder_bloc_edite` — aucun variant `LineBreak` nécessaire dans le modèle

Usage Swift :
```swift
let api = try ChaqaqApi(cheminDb: path)
let id  = try api.creerDocument(titre: "Ma note")
let json = try api.obtenirDocumentJson(id: id)  // → Codable
```

### `app/Sources/` — Couche UI SwiftUI

**`Models.swift`** — miroirs Swift des types Rust sérialisés par serde :
- `DocumentFfi`, `BlockFfi`, `InlineTextFfi`, `InlineStyleFfi`, `BlockContentFfi` — tous `Codable`
- `InlineStyleFfi` / `BlockContentFfi` : enums avec `init(from:)` / `encode(to:)` custom pour le format externally-tagged de serde
- Helpers sur `BlockContentFfi` : `texteSimple`, `spansOuVide`, `estTodo`, `doneTodo`, `avecTexte`, `avecSpans`, `toAttributedString`

**`RichTextEditor.swift`** — éditeur de texte riche :
- `ExpandingTextView : UITextView` — hauteur automatique via `intrinsicContentSize`
- `RichTextEditor : UIViewRepresentable` — bindings `spans`, `isFocused`, callbacks `onSave`, `onNewBlock`, `onConvert`
- `spansVersNSAttributed` / `nsAttributedVersSpans` — conversion aller-retour avec `.chaqaqColor` custom key pour le nom de couleur
- `NSAttributedString.Key.chaqaqColor` — attribut custom pour stocker le nom de couleur (round-trip fiable)
- Toolbar pill (style Notes.app) : `UIView` custom avec fond adaptatif, `UIScrollView` horizontal, boutons B/I/U + cercles couleur + dismiss clavier
- `fontAvecTraits(_:bold:italic:)` — gras/italique robuste avec fallback `boldSystemFont`/`italicSystemFont` (SF Pro ne supporte pas toujours `withSymbolicTraits`)
- Raccourcis markdown dans `textViewDidChange` : `# ` → H1, `## ` → H2, `### ` → H3, `> ` → Quote, `[ ] ` → Todo, `---` → Divider

**`ContentView.swift`** — écran d'accueil :
- `ChaqaqStore : ObservableObject` — connecte `ChaqaqApi`, liste les documents, CRUD
- Salutation dynamique (Bonjour/Bon après-midi/Bonsoir)
- `NavigationLink` → `DocumentView`
- FAB `square.and.pencil`, état vide illustré, date relative formatée

**`DocumentView.swift`** — éditeur de document :
- `EditableBlock` — modèle en mémoire : `id`, `content: BlockContentFfi`, `spans: [InlineTextFfi]`, `done: Bool`
- `DocumentViewModel : ObservableObject` — `charger`, `sauvegarderBloc`, `ajouterBloc`, `supprimerBloc`, `deplacerBloc` + `reordonnerBlocs`
- Mutations en mémoire directe (pas de rechargement depuis SQLite après insert/delete — évite l'effacement du contenu en cours d'édition)
- Blocs supportés : Text, Heading (1/2/3), Quote, Todo, Divider
- `ForEach($vm.blocs) { $bloc in }` — two-way binding pour l'édition en place
- Drag & drop natif via `.onMove` + `EditMode`
- Swipe-to-delete + menu contextuel
- `.scrollDismissesKeyboard(.interactively)` — dismiss clavier par swipe natif
- `autoFocusId` — focus automatique sur le bloc nouvellement créé

## Roadmap

Ce qui est **fait** — backend Rust + UI SwiftUI :
- Parser inline complet (bold, italic, underline, color, link, combinaisons)
- Types de blocs et documents avec blocs imbriqués récursifs
- `DocumentMeta` pour `list()` sans charger tout le contenu
- Erreurs custom `ChaqaqError` (plus de `Box<dyn Error>`)
- `RichText` + `EditorState` : édition en mémoire (curseur, sélection, toggle style)
- Undo/redo via pattern Command (`Historique` avec capacité configurable)
- Moteur database type Notion (propriétés, entrées, vues, filtres, tris, rollup, relation)
- CRUD complet blocs : ajouter, modifier, supprimer, réordonner (racine et enfants), imbriquer, déplacer
- Bridge éditeur → persistance (`sauvegarder_bloc_edite`)
- Recherche documents par titre + plein texte dans les blocs
- Recherche dans les entrées de database
- Gestion complète des propriétés (ajout, renommage, suppression)
- Gestion complète des vues (ajout, modification filtres/tris, suppression)
- **SQLite local-first** : `SqliteDocumentStore` + `SqliteDatabaseStore` avec soft delete, `updated_at`, migrations versionnées
- `JsonStore` + `DatabaseStore` JSON (conservés pour les tests)
- **Couche FFI UniFFI** : `ChaqaqApi` exposée à Swift, bindings `swift-bindings/` générés
- **XCFramework** : `chaqaq.xcframework` compilé (ios-arm64, ios-arm64-simulator, macos-arm64)
- **Projet Xcode** : `app/Chaqaq.xcodeproj` généré par xcodegen, lié au XCFramework
- **UI SwiftUI complète** :
  - Écran d'accueil avec liste de documents, salutation dynamique, FAB, création via sheet
  - Éditeur de document : blocs Text, Heading (×3), Quote, Todo, Divider
  - Texte riche : gras, italique, souligné, couleurs (rouge, bleu, orange, violet)
  - Toolbar de formatage pill (style Notes.app) avec scroll horizontal
  - Raccourcis markdown : `# `, `## `, `### `, `> `, `[ ] `, `---`
  - Enter → nouveau bloc, drag & drop natif, swipe-to-delete
  - Dismiss clavier par swipe vers le bas (`.scrollDismissesKeyboard(.interactively)`)
  - Focus automatique sur le bloc créé

Ce qui **reste** à construire :
1. UI Databases (backend Notion complet existe, aucune vue SwiftUI)
2. Barre de recherche (backend full-text existe, pas d'UI)
3. Vue iPad / Mac (NavigationSplitView)
4. Sync entre appareils (CRDT — s'inspirer de y-octo) — `updated_at` et soft delete déjà en place

## Code style

### Langue
- **Code en anglais** : tous les identifiants (types, fonctions, variables, champs, paramètres, méthodes FFI) en anglais idiomatique. Pas d'identifiants français (pas de `creer`, `titre`, `bloc`…).
- **Commentaires en français** : tout commentaire, doc-comment et explication inline est en français.
- **Chaînes utilisateur en français** : `Text("Bonjour")`, `placeholder("Titre du document")`, `accessibilityLabel("Annuler")` — restent en français car visibles par l'utilisateur final francophone.

### Conventions
- Pas de `unwrap()` — toujours `?` et `Result` côté Rust
- Nommage idiomatique : Rust `snake_case`/`PascalCase`, Swift `camelCase`/`PascalCase`
- `flush()` pattern pour les parsers

### Architecture — SOLID + Clean Architecture
- **Single Responsibility** : chaque module/type fait une chose. Domain (types purs), application (use cases + traits), infrastructure (stockage), ffi (adaptateur). Pas de "God objects".
- **Open/Closed** : ajout d'une fonctionnalité = nouveau type/impl, pas de modification des use cases. Les `match` exhaustifs forcent par le compilateur à traiter chaque variant ajouté (voulu).
- **Liskov** : toute impl de `DocumentRepository`/`DatabaseRepository` doit être strictement substituable (les tests tournent sur `MockRepo`, la prod sur `SqliteDocumentStore`).
- **Interface Segregation** : un trait = un rôle. `DocumentRepository` et `DatabaseRepository` sont séparés ; un client documents ne dépend pas des méthodes database.
- **Dependency Inversion** : les use cases dépendent d'abstractions (`&dyn DocumentRepository`), jamais de stores concrets. Seul `ffi.rs` (composition root) connaît les implémentations concrètes (`SqliteDocumentStore`).

### Résilience (back + front)
- **Erreurs typées, pas de panic** : `Result<T, ChaqaqError>` côté Rust, throws/Result côté Swift. Jamais de `unwrap()`/`!` en production.
- **Conversion d'erreurs aux frontières** : `From<E>` Rust (cf. `From<CoreError> for ChaqaqError` FFI) ; mapping en `ChaqaqError` côté Swift via `do/catch` qui remonte un `errorMessage: String?` au store.
- **Pas de couplage à l'impl** : `ChaqaqError::Db(String)` convertit les erreurs `rusqlite` en string pour ne pas coupler l'application à SQLite.
- **Retry avec backoff exponentiel** : `application/resilience.rs::retry_with_backoff` (3 essais, 50ms→500ms doublés) wrappe les opérations SQLite write/read. `is_transient()` ne retente que les erreurs verrou/I/O bloquante, jamais les erreurs métier (`NotFound`, `InvalidOperation`).
- **Validation aux frontières FFI** (`ffi.rs`) :
  - `parse_uuid` rejette les UUID malformés en `InvalidOperation`
  - `parse_json` refuse les payloads > **5 Mo** (`MAX_JSON_BYTES`)
  - `check_string` refuse les chaînes > **64 Ko** (`MAX_STRING_BYTES`) — appliqué à title/query/new_name
- **Soft delete + `updated_at`** : pas d'effacement dur, préparation CRDT/sync. Toute écriture passe par `save()` qui met à jour `updated_at`.
- **Mutations UI optimistes** : mémoire d'abord (les blocs en mémoire), persistance ensuite — évite l'effacement du contenu en cours de frappe lors d'un rechargement SQLite. La désync mémoire/disque est détectée au rechargement.
- **Concurrence** : SQLite en `WAL` pour la lecture concurrente. `@MainActor` côté Swift pour les view models. Pas d'accès direct au store hors façade.
- **UX erreur Swift** (`Resilience.swift`) :
  - `ChaqaqError.userMessage` → message français lisible par utilisateur (au lieu de l'erreur brute)
  - `ChaqaqError.isRecoverable` → true pour `Storage` (retry possible)
  - `tryCatch(into: &errorMessage)` capture l'erreur sans propager, remonte le message au view model
  - `.errorAlert(message:onRetry:)` modificateur SwiftUI qui présente l'alert avec bouton « Réessayer » optionnel
- **Tests à 3 niveaux côté Rust** : unitaires (`#[cfg(test)] mod tests` dans chaque module — y compris `resilience.rs` avec 6 tests), intégration (`tests/integration_*`), E2E (`tests/e2e_*`). 204+ tests.
- **Tests à 3 niveaux côté Swift** : `app/Tests/Unit/` (Swift Testing — `@Suite`/`@Test`/`#expect`, code pur), `app/Tests/Integration/` (Swift ↔ FFI réelle avec DB SQLite temporaire), `app/Tests/UI/` (XCUITest — pilote l'app comme utilisateur). Cibles xcodegen : `ChaqaqTests`, `ChaqaqIntegrationTests`, `ChaqaqUITests`. **186+ tests Swift.**

**Commandes de test** :
```bash
# Rust seul (rapide, sans simulateur) :
cargo test

# Swift complet (tous niveaux, nécessite simulateur booté) :
xcodebuild test -project app/Chaqaq.xcodeproj -scheme Chaqaq -destination 'id=<UDID>'

# Swift unit + integration seulement (rapide, pas de XCUITest) :
xcodebuild test -project app/Chaqaq.xcodeproj -scheme Chaqaq -destination 'id=<UDID>' \
    -only-testing:ChaqaqTests -only-testing:ChaqaqIntegrationTests

# Swift UI seulement :
xcodebuild test -project app/Chaqaq.xcodeproj -scheme Chaqaq -destination 'id=<UDID>' \
    -only-testing:ChaqaqUITests
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
- `NSAttributedString.Key.chaqaqColor` stocke le nom de couleur (String) en parallèle de `.foregroundColor` pour un round-trip `NSAttributedString ↔ [InlineTextFfi]` fiable.

## Dette technique — à reprendre avant scaling / mise en prod sérieuse

Ces points sont **acceptables en l'état actuel** (projet solo, 401 tests locaux) mais devront être traités avant d'ouvrir aux contributeurs / déployer en App Store. Ordre de priorité :

### Infrastructure (haute priorité dès qu'on collabore)
- **CI GitHub Actions** : workflow qui lance `cargo test` + `xcodebuild test` sur chaque push/PR. Sans ça, la suite de 401 tests est purement locale et "chez moi ça marche" devient le mode opératoire.
- **Code coverage** : `xcodebuild -enableCodeCoverage YES` (Swift) + `cargo-llvm-cov` (Rust). On compte les tests mais on ne connaît pas leur couverture réelle (peut être 30% ou 90%).
- **Workflow contributeur** : feature branches + PRs reviewables au lieu de gros sessions tout-en-un.

### Tests à renforcer
- **Coordinator class** (`RichTextEditor.Coordinator`) : selection memory (`rememberSelection`/`selectionForToolbar`), toolbar state updates (`updateToolbar`), color application chain — tout n'est testé qu'**en bout-en-bout** via le VM. Un bug subtil dans cette logique passerait. Extraire en helpers libres ou exposer pour tests.
- **`integration_retry.rs`** : prouve que les ops concurrentes ne cassent pas, **pas** que le retry se déclenche vraiment (test passe en 0.16s, scheduler n'a probablement pas créé de contention). Pour valider l'activation : ajouter point d'injection (mock connection avec `busy_timeout=0` + lock forcé) qui force un retry attendu.
- **`ActionRepeater` async test** : utilise `Task.sleep(220ms)` puis vérifie `≥3 ticks`. Flaky-prone sous CI chargée. Remplacer par mock timer (interface `Timer`-like injectable).
- **Database FFI** : 13 tests sur une surface énorme. Manque : `queryWithRollups` avec vrais Relation + Aggregate (j'ai juste testé que DB vide retourne `[]`), filters complexes (`Equal`/`Contains` avec valeurs typées), `groupedQuery` avec données, `MultiSelect`/`Relation`/`Date` round-trip JSON.
- **Markdown shortcuts E2E** : `markdownShortcut(for:)` helper unit-testé, mais le déclenchement effectif via `textViewDidChange` jamais validé end-to-end (faut taper "# " puis vérifier conversion).
- **`errorAlert` SwiftUI** : modificateur testé indirectement via les helpers Resilience, jamais visuellement. Ajouter snapshot testing (`swift-snapshot-testing`) pour les composants UI critiques.

### Limitations connues à résoudre
- **`typeText` flaky sur simulateur iOS 26** : bypass actuel via launch args `--ui-test-data`/`--ui-test-clean`. **Blocage** : impossible de tester E2E les flows demandant vraie saisie utilisateur (édition de titre dans la sheet de création, recherche). Pistes : `UIPasteboard` + long-press + Coller, `app.keys["X"].tap()` sur le clavier software, custom URL scheme pour pré-remplir.
- **`xcframework` métadonnées trackées** (136K headers + plist) : `.a` binaires gitignored, mais headers + Info.plist en git. Acceptable car petit, mais idéalement reconstruit par CI sur chaque release.

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
