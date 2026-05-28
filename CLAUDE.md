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
  main.rs          — point d'entrée démo
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

## Roadmap

Ce qui est **fait** — backend Rust complet (113 tests) :
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
- `updated_at` exposé dans `DocumentMeta` et `DatabaseMeta` — tri par "modifié récemment" possible côté UI
- `JsonStore` + `DatabaseStore` JSON (conservés pour les tests)

Ce qui **reste** à construire :
1. Décision finale UI (Flutter + flutter_rust_bridge vs Slint vs autre)
2. Couche UI : rendu des blocs, interaction clavier, drag & drop
3. Sync entre appareils (CRDT — s'inspirer de y-octo) — `updated_at` et soft delete déjà en place

## Code style
- Commentaires en français
- Pas de `unwrap()` — toujours `?` et `Result`
- Nommage idiomatique Rust (snake_case, PascalCase)
- `flush()` pattern pour les parsers

## Notes
- `#![allow(dead_code)]` intentionnel tant que l'UI n'est pas connectée.
- `#[serde(alias = "style")]` sur `InlineText.styles` pour charger les anciens JSON.
