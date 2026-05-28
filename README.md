# chaqaq

Application de notes personnelle combinant la fluidité de Craft et la structure de Notion — core en Rust pur.

> Statut : **backend complet** (117 tests) · **XCFramework compilé** · **UI SwiftUI fonctionnelle** (éditeur rich text, blocs, toolbar formatage)

---

## Vision

chaqaq est une app de prise de notes avec deux ambitions :

- **Beauté et fluidité** à la Craft : rendu natif, blocs riches, inline styles
- **Structure et puissance** à la Notion : databases, vues, filtres, relations, rollups

Le projet est entièrement écrit en Rust pour le core. L'objectif à terme est une publication open source — un rich text editor en Rust complet n'existe pas encore dans l'écosystème.

Plateformes cibles : iPhone, iPad, Mac.

---

## Architecture

Clean Architecture stricte — la règle de dépendance va dans un seul sens :

```
infrastructure → application → domain
```

```
src/
  domain/
    document.rs       — types de base (InlineStyle, Block, Document, DocumentMeta)
    parser.rs         — parser inline markdown-like
    rich_text.rs      — RichText : string plate + spans pour l'édition
    editor.rs         — EditorState : curseur, sélection, toggle style
    commandes.rs      — Command pattern : undo/redo
    database.rs       — moteur database type Notion
  application/
    repository.rs          — trait DocumentRepository
    use_cases.rs           — use cases documents et blocs
    database_repository.rs — trait DatabaseRepository
    database_use_cases.rs  — use cases database
    error.rs               — ChaqaqError
  infrastructure/
    migrations.rs            — migrations SQLite versionnées
    sqlite_document_store.rs — SqliteDocumentStore (local-first, recommandé)
    sqlite_database_store.rs — SqliteDatabaseStore (local-first, recommandé)
    json_store.rs            — JsonStore (conservé pour les tests)
    database_store.rs        — DatabaseStore JSON (conservé pour les tests)
  ffi.rs             — façade UniFFI : ChaqaqApi exposée à Swift
  chaqaq.udl         — interface UDL (contrat Swift ↔ Rust)
swift-bindings/      — bindings Swift générés (chaqaq.swift, chaqaqFFI.h)
chaqaq.xcframework   — XCFramework compilé (iOS device + simulator + macOS)
app/                 — application SwiftUI
  Sources/
    ChaqaqApp.swift      — @main
    ContentView.swift    — écran d'accueil + ChaqaqStore
    DocumentView.swift   — éditeur de document + DocumentViewModel
    Models.swift         — miroirs Swift Codable des types Rust
    RichTextEditor.swift — UIViewRepresentable + toolbar pill de formatage
```

---

## Fonctionnalités (backend)

### Documents et blocs

- Blocs supportés : `Text`, `Heading` (niveaux), `Quote`, `Todo`, `Divider`, `Breadcrumb`, `Database`
- Blocs imbriqués récursifs avec enfants
- CRUD complet : créer, lire, modifier, supprimer
- Réordonnement à la racine et dans les enfants
- Déplacement d'un bloc vers n'importe quel parent (ou racine)
- Métadonnées légères (`DocumentMeta`) pour lister sans charger tout le contenu, avec `updated_at` pour trier par "modifié récemment"

### Inline styles (parser)

```
**gras**          → Bold
_italique_        → Italic
__souligné__      → Underline
{rouge:texte}     → Color("rouge")
[texte](url)      → Link(url)
**_combiné_**     → Bold + Italic
```

### Rich text editor (in-memory)

- `RichText` : représentation par chars Unicode + spans de styles
- Insertion et suppression avec décalage automatique des spans
- Toggle de style sur une sélection
- Conversion aller-retour vers `Vec<InlineText>` pour la persistance
- `EditorState` : curseur, sélection, navigation
- Undo/redo via pattern Command avec capacité configurable

### Database (type Notion)

**Types de propriétés :** Titre, Texte, Nombre, Sélection, Sélection multiple, Date, Case, URL, Relation, Rollup

**Vues :** Tableau, Kanban, Calendrier, Galerie

**Opérations :**
- Filtres (`EstVide`, `EstPlein`, `Egal`, `Contient`)
- Tris avec `SourceTri` : par propriété, par date de création, ou date manuelle puis création (utile pour les journaux)
- Groupement par valeur de propriété
- Rollups calculés à la lecture (Compter, Somme, Moyenne, Min, Max)
- Relations entre databases
- Gestion complète des propriétés (ajout, renommage, suppression avec nettoyage des valeurs)
- Gestion complète des vues (ajout, modification des filtres/tris, suppression)

### Recherche

- Par titre de document (insensible à la casse)
- Plein texte dans le contenu des blocs (récursif dans les enfants)
- Dans les valeurs textuelles des entrées de database

### Stockage (local-first)

Architecture **local-first, offline-first** — chaque device a sa propre base SQLite embarquée.

- `SqliteDocumentStore` / `SqliteDatabaseStore` : stockage recommandé pour la production
- Schéma document-as-JSON : le blob complet est dans une colonne `data`, les métadonnées (`title_text`, `title_json`, `cover`) sont indexées séparément pour un listing rapide sans désérialiser les blocs
- `updated_at` géré automatiquement à chaque écriture
- **Soft delete** : `delete()` pose un `deleted_at` au lieu de supprimer — les données restent disponibles pour la sync CRDT future
- SQLite bundlé dans le binaire — pas de dépendance système, fonctionne sur iOS, Android et macOS
- Migrations versionnées via `rusqlite_migration` — évolutions de schéma sans perte de données
- `JsonStore` / `DatabaseStore` JSON conservés pour les tests

---

## Lancer le projet

```bash
# Backend Rust
cargo run     # point d'entrée démo
cargo test    # 117 tests (unitaires + intégration + E2E)
cargo check   # vérification rapide
cargo build

# Régénérer les bindings Swift après modification de ffi.rs ou chaqaq.udl
cargo run --bin uniffi-bindgen -- generate \
    --library target/debug/libchaqaq.dylib \
    --language swift --out-dir swift-bindings/

# Recompiler le XCFramework (après modification du code Rust)
./build-xcframework.sh

# App iOS (ouvrir dans Xcode)
cd app && xcodegen generate   # régénère le .xcodeproj si besoin
open app/Chaqaq.xcodeproj
```

---

## Roadmap

- [x] Parser inline complet
- [x] Types de blocs et documents
- [x] Rich text editor (RichText, EditorState, undo/redo)
- [x] Moteur database type Notion
- [x] CRUD complet documents, blocs, databases
- [x] Recherche (titres, contenu, entrées)
- [x] Erreurs custom (`ChaqaqError`)
- [x] Persistance JSON (proto/tests)
- [x] Stockage SQLite local-first (soft delete, updated_at, migrations, bundled)
- [x] Couche FFI UniFFI — `ChaqaqApi` exposée à Swift
- [x] Bindings Swift générés (`swift-bindings/`)
- [x] XCFramework compilé (ios-arm64, ios-arm64-simulator, macos-arm64)
- [x] Projet Xcode — `app/Chaqaq.xcodeproj` via xcodegen
- [x] Écran d'accueil SwiftUI (liste, FAB, salutation, date relative)
- [x] Éditeur de document (blocs Text / Heading / Quote / Todo / Divider)
- [x] Texte riche : gras, italique, souligné, couleurs
- [x] Toolbar de formatage pill (style Notes.app)
- [x] Raccourcis markdown inline (`# `, `> `, `[ ] `, `---`)
- [x] Enter → nouveau bloc, drag & drop, swipe-to-delete
- [ ] UI Databases (vue Tableau, Kanban — backend complet)
- [ ] Barre de recherche (full-text — backend complet)
- [ ] Vue iPad / Mac (NavigationSplitView)
- [ ] Sync entre appareils (CRDT, s'inspirer de y-octo)

---

## Stack

| Crate | Rôle |
|---|---|
| `serde` + `serde_json` | Sérialisation / persistance JSON |
| `uuid` | Identifiants uniques |
| `chrono` | Timestamps ISO 8601 (`cree_le`, `updated_at`) |
| `rusqlite` (bundled) | SQLite embarqué — stockage local-first |
| `rusqlite_migration` | Migrations de schéma versionnées |
| `uniffi` | Bridge Rust ↔ Swift (bindings générés automatiquement) |
