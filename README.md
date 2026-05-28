# chaqaq

Application de notes personnelle combinant la fluidité de Craft et la structure de Notion — core en Rust pur.

> Statut : **backend complet** (95 tests). Couche UI en cours de décision.

---

## Vision

chaqaq est une app de prise de notes avec deux ambitions :

- **Beauté et fluidité** à la Craft : rendu natif, blocs riches, inline styles
- **Structure et puissance** à la Notion : databases, vues, filtres, relations, rollups

Le projet est entièrement écrit en Rust pour le core. L'objectif à terme est une publication open source — un rich text editor en Rust complet n'existe pas encore dans l'écosystème.

Plateformes cibles : iPhone, iPad, Mac, Web, Android.

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
    repository.rs         — trait DocumentRepository
    use_cases.rs          — use cases documents et blocs
    database_repository.rs — trait DatabaseRepository
    database_use_cases.rs  — use cases database
    error.rs              — ChaqaqError
  infrastructure/
    json_store.rs         — JsonStore (documents → {uuid}.json)
    database_store.rs     — DatabaseStore (databases → {uuid}.json)
```

---

## Fonctionnalités (backend)

### Documents et blocs

- Blocs supportés : `Text`, `Heading` (niveaux), `Quote`, `Todo`, `Divider`, `Breadcrumb`, `Database`
- Blocs imbriqués récursifs avec enfants
- CRUD complet : créer, lire, modifier, supprimer
- Réordonnement à la racine et dans les enfants
- Déplacement d'un bloc vers n'importe quel parent (ou racine)
- Métadonnées légères (`DocumentMeta`) pour lister sans charger tout le contenu

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

---

## Lancer le projet

```bash
cargo run     # point d'entrée démo
cargo test    # 95 tests (unitaires + intégration + E2E)
cargo check   # vérification rapide
cargo build
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
- [x] Persistance JSON
- [ ] Décision UI (Flutter + flutter_rust_bridge vs Slint vs autre)
- [ ] Couche UI : rendu des blocs, interaction clavier, drag & drop
- [ ] Sync entre appareils (CRDT, s'inspirer de y-octo)

---

## Stack

| Crate | Rôle |
|---|---|
| `serde` + `serde_json` | Sérialisation / persistance JSON |
| `uuid` | Identifiants uniques |
| `chrono` | Timestamps ISO 8601 (`cree_le`) |
