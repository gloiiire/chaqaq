# UI Audit — Parking Lot

Snapshot **2026-06-02** des manques UI identifiés. Document vivant : à compléter à chaque session de test in-app.

Légende :
- 🟢 **OK** : fonctionne aujourd'hui
- 🟡 **Partial** : marche mais incomplet / UX peu fine
- 🔴 **Missing** : pas encore implémenté
- 🐛 **Bug** : implémenté mais cassé

---

## Éditeur de document

| Feature | Status | Notes |
|---|---|---|
| Saisie texte (Text, Heading, Quote, Callout, Todo, Divider, List, Code) | 🟢 | |
| Toolbar pill : Paste / Aa (B/I/U/S) / Highlighter / ¶ block color | 🟢 | PR #97 |
| Toolbar pill : Undo / Redo | 🟢 | 1000 levels, burst typing |
| Toolbar pill : Indent / Outdent | 🟢 | PR #96 |
| Markdown shortcuts (`# `, `## `, `> `, `[ ] `, `---`) | 🟢 | |
| Drag & drop blocks | 🟢 | natif iOS |
| Block color rendu (inline > block priority) | 🟢 | PR #97 |
| Color picker pour TEXT (inline) | 🟢 | highlighter button |
| Color picker pour BACKGROUND | 🔴 | domain change requis (cf `IMPORT-AUDIT.md`) |
| Inline code (`code`) | 🔴 | manque dans `chaqaq::InlineStyle` |
| Block code language picker | 🔴 | Le bloc Code accepte `language: String` mais la UI ne l'expose pas |
| Block image / file / embed | 🔴 | domain change requis |
| Sélection de plusieurs blocs (multi-block ops) | 🟡 | swipe-to-delete OK, mais pas de "déplacer 3 blocs en même temps" |
| Search & replace dans un doc | 🔴 | backend search OK pour le full-text, pas exposé UI |
| Document cover image picker | 🟡 | Field exists côté domain, pas d'UI pour le choisir/importer |
| Document icon (emoji) | 🔴 | domain change requis |

---

## DB / Bases

| Feature | Status | Notes |
|---|---|---|
| List databases (home tab) | 🟢 | |
| Open database in DB view | 🟢 | |
| Rename row → propage au document | 🟢 | PR #95 |
| Tap column header → sort cycle asc/desc/none | 🟢 | PR #100 |
| Indicator arrow.up/down sur header trié | 🟢 | PR #100 |
| Tri multi-colonnes | 🔴 | V1 supporte un seul tri à la fois |
| Filtres UI | 🔴 | Backend OK, UI à faire |
| Switch entre views (Table / Kanban / Calendar / Gallery) | 🔴 | Backend OK, UI à faire |
| Vue Kanban | 🔴 | |
| Vue Calendar | 🔴 | |
| Vue Gallery | 🔴 | |
| Group-by visuel | 🔴 | Backend OK, UI à faire |
| Édition Rollup en lecture | 🟡 | Backend calcule, UI affiche, mais aucun "set rollup property" |
| Édition Relation : link picker | 🔴 | Aujourd'hui on tape un UUID à la main |
| Edit cell types : Number, Date, Checkbox, Select | 🟢 | |
| Edit cell : Multi-Select | 🟡 | À vérifier in-app |
| Edit cell : Title (texte enrichi) | 🟢 | propage au document |
| Add row | 🟢 | |
| Delete row | 🟢 | |
| Add column | 🟢 | |
| Rename column | 🟢 | context menu |
| Delete column | 🟢 | |
| Reorder columns | 🔴 | |
| Resize columns | 🔴 | Largeur fixe par type |

---

## Navigation / Home

| Feature | Status | Notes |
|---|---|---|
| Tab bar Notes / Bases / Recherche | 🟢 | iOS 26 TabView natif |
| Salutation dynamique | 🟢 | |
| Strip horizontale "Recents" (5 derniers docs) | 🟢 | |
| List complète avec swipe-to-delete | 🟢 | |
| FAB création doc | 🟢 | |
| Recherche full-text | 🟡 | Searchable + résultats OK ; pas de surlignage du match |
| Folders / hiérarchie | 🟡 | Backend complet, UI partielle |
| Navigation `pinkha://doc/{uuid}` (mention internes) | 🔴 | URL scheme défini par #101, l'app ne le résout pas encore |

---

## Imports

| Feature | Status | Notes |
|---|---|---|
| FAB menu "Import from Notion" | 🟢 | |
| FAB menu "Import from Bear" | 🟢 | |
| FAB menu "Import from Craft" | 🟢 | |
| OAuth Notion end-to-end | 🟢 | proxy Railway, Keychain persist |
| Progress bar pendant import | 🟡 | ProgressView spinner, pas de % |
| Import error recovery | 🟡 | Affichage du message d'erreur OK, pas de "retry" |
| Re-import (refresh) | 🔴 | Pas de "sync depuis Notion" récurrent — un import = un snapshot |

---

## iPad / Mac

| Feature | Status | Notes |
|---|---|---|
| Layout adapté iPad | 🔴 | NavigationSplitView à faire |
| Layout adapté Mac | 🔴 | |
| Keyboard shortcuts hardware | 🟡 | Bold/Italic/Underline OK, manque Redo / Find / etc. |

---

## Performance / Robustesse

| Feature | Status | Notes |
|---|---|---|
| Burst undo typing | 🟢 | |
| Cache spans rendu | 🟢 | |
| SQLite WAL + retry transient | 🟢 | |
| Sentry crash reporting | 🟢 | |
| Soft delete + updated_at | 🟢 | |
| Sync CRDT entre appareils | 🔴 | Big chunk, à inspirer de y-octo |

---

## Comment utiliser ce doc

1. Tu testes l'app
2. Tu trouves un bug ou un manque
3. Tu cherches s'il est déjà listé ici
4. Si oui, tu ajoutes des détails (steps to repro, screenshot path)
5. Si non, tu l'ajoutes dans la bonne section
6. Quand on attaque une feature, on crée une tâche issue + PR, en référençant ce doc
