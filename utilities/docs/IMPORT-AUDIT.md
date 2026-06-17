# Import Audit — Notion & Craft

Snapshot **2026-06-02** des features Notion / Craft / pinkha pour chaque type de bloc et de fidélité d'import. Sert de roadmap pour les prochaines features. Mettre à jour au fil des PRs.

Légende :
- ✅ **OK** : import préserve la donnée fidèlement
- 🟡 **Partial** : import marche, mais perd une info
- ❌ **Missing** : pas encore mappé, donnée perdue ou bloc skippé
- ⚪ **N/A** : feature absente côté source

---

## Inline styles

| Feature | Notion | Craft | Notes |
|---|---|---|---|
| Bold / Italic / Underline / Strikethrough | ✅ | 🟡 | Craft fait du parsing minimal — vérifier après PR #99 (block color) si l'inline style fonctionne |
| Color (text) | ✅ | ❌ | Craft : à investiguer si stocké via colonne `style` ou via runs séparés |
| Color (background) | ❌ | ❌ | Pinkha n'a pas encore de notion de background — domain change requis |
| Link `[label](url)` | ✅ | 🟡 | Craft : à vérifier |
| Inline equation | ❌ | ❌ | Pas dans `chaqaq::InlineStyle` — domain change requis |
| Inline code | ❌ | ❌ | Pas dans `chaqaq::InlineStyle` — domain change |
| Mention (page link interne) | ✅ | ❌ | PR #101 : URLs Notion → `pinkha://doc/{uuid}` au post-pass. Craft : à investiguer |

---

## Block types

| Bloc Notion | Bloc Craft | Pinkha `BlockContent` | Status |
|---|---|---|---|
| paragraph | text | Text | ✅ |
| heading_1/2/3 | text H1/H2/H3 (md) | Heading {level} | ✅ |
| quote | quote | Quote {icon:None} | ✅ |
| callout | callout | Quote {icon:emoji} | ✅ Notion — Craft à vérifier |
| to_do | text "[ ]" | Todo {done} | ✅ Notion — Craft à vérifier |
| bulleted_list_item | bullet list | BulletedListItem | ✅ |
| numbered_list_item | numbered list | NumberedListItem | ✅ |
| divider | line | Divider | ✅ |
| code | code | Code {language, text} | ✅ |
| toggle | ⚪ | ❌ | Notion-only. Mappé en `Quote` ? `Text` ? À décider |
| image | image | ❌ | Pas dans BlockContent — domain change pour `Image {url, caption}` |
| video / file / audio | file | ❌ | Pareil — `File {url, name, mime}` |
| embed (URL preview) | embed | ❌ | Idem |
| bookmark | ⚪ | ❌ | Notion-only. Mappable en `Text` avec inline link en attendant |
| table | table | ❌ | Bloc complexe. Pinkha a déjà des Databases, à voir si on les détourne ou si on ajoute un `Table {rows}` simple |
| column_list / column | ⚪ | ❌ | Layout multi-colonnes. Pas prioritaire |
| equation (block) | ⚪ | ❌ | Math block. Niche |
| sync_block | ⚪ | ❌ | Avancé Notion. Niche |
| breadcrumb | ⚪ | ✅ (Breadcrumb) | Mais pas de mapping Notion → Pinkha Breadcrumb |
| child_database | ⚪ | ✅ (Database) | Pas mappé : aujourd'hui on importe les DB séparément |
| ⚪ | folder hiérarchique | ✅ (via FolderRepository) | Craft : à valider que la hiérarchie folder est bien préservée |

---

## Page-level features

| Feature | Notion | Craft | Notes |
|---|---|---|---|
| Title (text) | ✅ | ✅ | |
| Cover image | ❌ | ❌ | Notion expose `cover.external.url`. Pinkha a `Document.cover: Option<String>` mais on ne le remplit pas à l'import. **Quick win** |
| Icon (emoji ou image) | ❌ | ❌ | Notion expose `icon.emoji`. Pinkha n'a pas de champ Document.icon — domain change ou stocker dans le cover |
| Created/Updated timestamps | ⚪ | ⚪ | Notion expose mais on regénère côté pinkha. Acceptable pour l'instant |
| Page comments | ⚪ | ⚪ | Aucune des sources ne le fournit via API publique |

---

## Database (Notion)

| Feature | Status | Notes |
|---|---|---|
| Property types: Title, Text, Number, Select, MultiSelect, Date, Checkbox, URL | ✅ | |
| Property types: Email, Phone, Files, People, Created_by, Last_edited_by, Last_edited_time | ❌ | Quelques-uns mappables en Text. Les autres pas dans Pinkha |
| Property types: Formula | ❌ | Bloc complexe. Évaluation des formules out-of-scope |
| Property types: Relation | 🟡 | Mappé en PropertyType::Relation côté Pinkha — mais on n'importe que l'ID, pas la résolution du target |
| Property types: Rollup | 🟡 | Pinkha a Rollup, mais le mapping Notion rollup→Pinkha rollup pas fait |
| Views (Table) | ✅ | Vue par défaut auto-créée |
| Views (Kanban / Calendar / Gallery) | ❌ | Pinkha les supporte côté domain, pas mappés à l'import |
| Filters | ❌ | Pinkha les supporte mais pas mappés |
| Sorts | ❌ | Pareil. PR #100 expose le tri dans l'UI mais on ne préserve pas les sorts Notion à l'import |
| Group-by | ❌ | Pinkha le supporte, pas mappé |

---

## Recommandation d'ordre pour les prochaines PRs

### Quick wins (≤ 1 PR chacune)
1. **Cover Notion → Document.cover** : champ déjà présent, juste à mapper depuis `page.cover.external.url`.
2. **Icon Notion → Document.cover (provisoirement)** : si l'icon est un emoji, on le stocke dans cover. Domain change propre = ajout de `Document.icon`.
3. **Bookmark Notion → Text + inline link** : préserve l'info utile sans nouveau type de bloc.

### Domain changes (un cycle de plus pour chacun)
4. **`InlineStyle::Code`** : ajoute le inline code dans chaqaq. Mapping Notion direct.
5. **`InlineStyle::Equation` ou `BlockContent::Equation`** : pour les utilisateurs scientifiques.
6. **`BlockContent::Image { url, caption }`** : préserver les images Notion/Craft.
7. **`BlockContent::File { url, name }`** : pareil pour les attachments.

### Plus gros chantiers
8. **Mapping Notion views/filters/sorts → Pinkha** : profite du backend existant côté pinkha (PR #100).
9. **Table block** : décider si on détourne Database ou on ajoute un type simple.
10. **Audit Craft schéma réel** : actuellement on probe des colonnes sans certitude. Une session d'inspection d'un vrai `.realm` pour identifier les vraies colonnes (`style`, `colorName`, etc.) clarifie tout.

---

## TODO documenté côté code

- `src/extractors/craft/mod.rs::craft_color_name_to_pinkha` — mapping speculatif, étendre avec les valeurs Craft réelles
- `src/extractors/craft_combined/mod.rs` — n'extrait pas encore la couleur dans le mode combined
- Notion : pas de mapping pour `image_block`, `file`, `embed`, `bookmark`, `equation`, `toggle`, `table`, `column_list`
