# Pinkha — vocabulaire métier

> Univers physique de la bibliothèque/atelier. Tout est dérivé du
> couple **Leaf** (la feuille écrite) + **Book** (le recueil relié),
> avec une grammaire d'actions cohérente.

## Modèle mental

```
🏛️  Library (workspace)
   └─ 📚 Shelves (folders)
        └─ 📖 Books (databases / collections relié)
             └─ 🍃 bound Leaves (rows = feuilles reliées au livre)
        └─ 🍃 loose Leaves (feuilles volantes, standalone documents)
   └─ 🍃 loose Leaves at root
```

Une feuille peut être **loose** (volante, standalone) ou **bound**
(reliée à un Book, devient sa row). C'est physiquement cohérent avec
l'objet "feuille" : prends une feuille blanche, écris dessus, soit
tu la laisses sur ton bureau (loose), soit tu la relies dans un livre
(bound).

## Glossaire — concept → identifier

| Concept actuel        | Nouveau nom        | Identifier code            |
| --------------------- | ------------------ | -------------------------- |
| Document              | **Leaf**           | `Leaf`, `leaf_id`          |
| Database              | **Book**           | `Book`, `book_id`          |
| Entry (row in DB)     | **BoundLeaf**      | `BoundLeaf` (le row)       |
| Folder                | **Shelf**          | `Shelf`, `shelf_id`        |
| Workspace (tab)       | **Library**        | `Library` (UI only)        |
| Trash                 | **Compost**        | `Compost`                  |

## Grammaire d'actions

| Action                       | Verbe                         | Exemple UX                                    |
| ---------------------------- | ----------------------------- | --------------------------------------------- |
| Create document              | **take** a leaf               | `+ New leaf` → "Take a leaf"                  |
| Create database              | **open** a book               | `+ New book` → "Open a book"                  |
| Create folder                | **build** a shelf             | `+ New shelf` → "Build a shelf"               |
| Add doc as row of DB         | **bind** a leaf to a book     | Long-press leaf → "Bind to a book…"           |
| Remove row                   | **unbind**                    | Long-press row → "Unbind"                     |
| Move to folder               | **shelve** in…                | Long-press → "Shelve in My Travel Shelf"      |
| Move to trash                | **discard** to compost        | Swipe → "Discard"                             |
| Restore from trash           | **rake** out                  | Trash row → "Rake out" (option)               |
| Bookmark                     | **bookmark**                  | Star a leaf → "Bookmarked"                    |
| Browse / search              | **browse** / **search**       | Standard                                      |
| Recently opened              | **recently leafed**           | Home strip → "Recently leafed"                |

## États (adjectifs)

- **Loose leaf** = feuille volante (standalone document)
- **Bound leaf** = feuille reliée (row d'un Book)
- **Shelved** = rangée dans une étagère
- **Composted / discarded** = à la poubelle

## Internationalisation

| EN                 | FR                  |
| ------------------ | ------------------- |
| Library            | Bibliothèque        |
| Shelf / Shelves    | Étagère / Étagères  |
| Book / Books       | Livre / Livres      |
| Leaf / Leaves      | Feuille / Feuilles  |
| loose leaf         | feuille volante     |
| bound leaf         | feuille reliée      |
| Compost            | Compost             |
| New leaf           | Nouvelle feuille    |
| New book           | Nouveau livre       |
| New shelf          | Nouvelle étagère    |
| Take a leaf        | Prendre une feuille |
| Open a book        | Ouvrir un livre     |
| Build a shelf      | Monter une étagère  |
| Bind to a book     | Relier au livre     |
| Unbind             | Détacher            |
| Shelve in…         | Ranger dans…        |
| Discard            | Composter           |

## Termes préservés (ne pas renommer)

Ces termes appartiennent à des contextes externes ou techniques et
restent inchangés :

- **NotionDatabase**, **NotionDatabaseSummary**, etc. — terminologie
  API Notion (Notion utilise "page" et "database" dans son schéma
  public, et l'extracteur Pinkha doit refléter ce vocabulaire pour
  matcher la docs Notion).
- **child_database**, **ChildDatabase** — même raison, type de bloc
  Notion.
- **DocumentDataModel** — type externe de Realm/Craft.
- **db_path** — chemin de fichier SQLite (couche stockage, pas le
  Book Pinkha).
- **dbg!**, **dbg::** — macros / chemins Rust standard.
- **documentation**, **documented**, **documenting** — anglais
  courant qu'on ne réécrit pas en "pageation" / "leafation".

## Fichiers / dossiers — mapping

### Rust

| Avant                                  | Après                                |
| -------------------------------------- | ------------------------------------ |
| `src/domain/document.rs`               | `src/domain/leaf.rs`                 |
| `src/domain/database/`                 | `src/domain/book/`                   |
| `src/domain/database/database.rs`      | `src/domain/book/book.rs`            |
| `src/application/document_repository.rs` | `src/application/leaf_repository.rs` |
| `src/application/database_repository.rs` | `src/application/book_repository.rs` |
| `src/application/database_use_cases/`  | `src/application/book_use_cases/`    |
| `src/application/use_cases/document.rs` | `src/application/use_cases/leaf.rs`  |
| `src/application/use_cases/db_doc_sync.rs` | `src/application/use_cases/book_leaf_sync.rs` |
| `src/infrastructure/sqlite_document_store.rs` | `src/infrastructure/sqlite_leaf_store.rs` |
| `src/infrastructure/sqlite_database_store.rs` | `src/infrastructure/sqlite_book_store.rs` |
| `src/ffi/documents.rs`                 | `src/ffi/leaves.rs`                  |
| `src/ffi/databases.rs`                 | `src/ffi/books.rs`                   |

### Swift

| Avant                                   | Après                            |
| --------------------------------------- | -------------------------------- |
| `app/Sources/Document/`                 | `app/Sources/Leaf/`              |
| `app/Sources/Database/`                 | `app/Sources/Book/`              |
| `app/Sources/Workspace/`                | `app/Sources/Library/`           |
| `DocumentView.swift`                    | `LeafView.swift`                 |
| `DocumentViewModel.swift`               | `LeafViewModel.swift`            |
| `DatabaseView.swift`                    | `BookView.swift`                 |
| `DatabaseViewModel.swift`               | `BookViewModel.swift`            |
| `DatabasesHomeView.swift`               | `BooksHomeView.swift`            |
| `WorkspaceView.swift`                   | `LibraryView.swift`              |
| `FolderView.swift`                      | `ShelfView.swift`                |
| `TrashView.swift`                       | `CompostView.swift`              |

### SQLite — migrations

- Migration : `ALTER TABLE documents RENAME TO leaves;`
- Migration : `ALTER TABLE databases RENAME TO books;`
- Migration : `ALTER TABLE folders RENAME TO shelves;` (optionnel)
- Tous les indexes et triggers référençant ces tables doivent suivre.
- Migration unique versionnée — pas de rollback nécessaire en local.

## Justification de chaque choix

### Pourquoi Leaf (et pas Page, Document, Memo, Folio) ?

- **Page** : collision avec Notion qui utilise `page_id` partout dans son
  API. Disambiguer chaque variable en code serait pénible.
- **Document** : trop générique, ne donne pas d'identité de marque.
- **Memo** : connote du court. Une Leaf Pinkha peut être longue (50
  blocs, embedded books). Memo ne capture pas la richesse.
- **Folio** : trop technique / obscur. Risque rejet utilisateur.
- **Leaf** :
  - Sens **dual** : organique (feuille d'arbre) + technique (leaf d'un
    livre en typographie/édition).
  - Court (4 lettres), beau en code (`leaf_id`, `LeafView`).
  - Pair physique parfait avec Book : un livre est fait de feuilles.
  - Hérite d'expressions positives : *turn a new leaf* (fresh start),
    *take a leaf out of someone's book* (s'inspirer), *leaf through*
    (feuilleter).
  - Distinct des concurrents (Notion = page, Bear = note, Craft =
    document, Ulysses = sheet).

### Pourquoi Book ?

- Pair sémantique naturel avec Leaf (un livre est fait de feuilles).
- Pas de collision avec Notion (qui dit "database").
- Court, mémorable.
- En FR : "livre" — traduction directe.

### Pourquoi Shelf (pas Folder) ?

- Folder est technique/générique, casse l'univers organique.
- Une étagère contient des livres ET des feuilles volantes ET des
  sous-étagères — ce qui matche exactement ce qu'un folder Pinkha
  peut contenir.
- Verbe associé naturel : *shelve*.

### Pourquoi Library (pas Workspace) ?

- Workspace est OS/office-y, n'évoque rien de physique.
- Library est l'endroit où on range les livres et les feuilles.
- Joue avec l'univers complet.

### Pourquoi Compost (pas Trash) ?

- Trash est neutre / OS-générique.
- Compost reste dans l'univers organique (feuilles tombées → compost).
- Connotation positive (recyclage, rien de jeté définitivement).
- *"Restore from compost"* sonne mieux que *"Restore from trash"*.

## Apps qui auraient pu prendre Leaf et ne l'ont pas pris

- **Notion** → page / database
- **Bear** → note
- **Craft** → document
- **Ulysses** → sheet
- **Obsidian** → note
- **Apple Notes** → note
- **iA Writer** → document

L'espace **Leaf** est libre. Opportunité de différenciation forte.
