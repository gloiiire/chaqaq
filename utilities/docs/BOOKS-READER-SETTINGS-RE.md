# Apple Books "Thèmes et réglages" — Reverse-engineering findings (iOS 26.5.1)

Source : Books.app + frameworks (`BookEPUB`, `Books`) extracted from
`iPhone18,1_26.5.1_23F81_Restore.ipsw`, class-dumped with `ipsw class-dump`.
Build : iOS 26.5, SDK 26.5, Source 6570.0.0.0.0 (BookEPUB).

Headers extracted to `safari_re/books_extracts/headers/{BookEPUB,Books,BookCore,BookStoreUI,BlissReader,TemplateUI,BookEPUB}/`.

---

## 1. Architecture map (confirmed from class-dump)

Apple uses VIPER-style separation across **two view models**, one for the
main sheet and one for the customization sub-sheet :

```
ReaderSettingsViewModel   ← main "Thèmes et réglages" sheet
    │
    └─ ThemeOptionsViewModel   ← "Personnaliser le thème" sub-sheet
            │
            └─ ThemeFontViewModel  ← font picker row
```

Each view model is paired with a `Presenter` + `Interactor` + `DataManager`
(classic Clean Architecture).

```
BookEPUB:
    _TtC8BookEPUB22ReadingSettingsManager
    _TtC8BookEPUB24ReadingSettingsViewModel
    _TtC8BookEPUB24ReadingSettingsPresenter
    _TtC8BookEPUB25ReadingSettingsInteractor
    _TtC8BookEPUB26ReadingSettingsDataManager
    _TtC8BookEPUB21ThemeOptionsViewModel
    _TtC8BookEPUB21ThemeOptionsPresenter
    _TtC8BookEPUB22ThemeOptionsInteractor
    _TtC8BookEPUB23ThemeOptionsDataManager
    _TtC8BookEPUB18BookThemeViewModel       ← one per tile in the grid
    _TtC8BookEPUB18ThemeFontViewModel       ← one per font in picker
    _TtC8BookEPUB22ThemeAppearanceManager   ← drives light/dark variant
    _TtC8BookEPUB23CurrentThemePersistence
    BookTheme                               ← Core Data NSManagedObject

Books (main app):
    _TtC5Books20BrightnessController        ← UIScreen.brightness wrapper
    _TtC5Books26BookReaderChromeController  ← hides toolbars in reader
    _TtC5Books28BookReaderThemeChangeWatcher
```

---

## 2. `BookTheme` — the persistent data model

From `safari_re/books_extracts/headers/BookEPUB/BookEPUB/BookTheme.h` :

```objc
@interface BookTheme : NSManagedObject
@property (nonatomic) short    multipleColumnMode;
@property (nonatomic, copy)    NSDictionary *fontsByLanguage;
@property (nonatomic) BOOL     hasCustomLayout;
@property (nonatomic, copy)    NSString *identifier;
@property (nonatomic) BOOL     isFontBolded;
@property (nonatomic) BOOL     justify;
@property (nonatomic) double   letterSpacing;
@property (nonatomic) double   lineHeight;
@property (nonatomic) double   wordSpacing;
@property (nonatomic) double   marginAdjustment;
@end
```

**Key insight #1** — All typography overrides live on the **theme**, not on
the book. Mapping to our app : the per-leaf settings should also be theme-
scoped (a leaf inherits the theme, and the theme carries the typography).

Our Rust mirror (proposed) :

```rust
// crates/pinkha or src/domain/theme.rs
pub struct ReaderTheme {
    pub identifier: String,          // "tranquille", "papier", etc.
    pub font_family: Option<String>, // None → system default
    pub is_font_bolded: bool,
    pub justify: bool,
    pub line_height: f64,            // 1.0 .. 2.4
    pub letter_spacing: f64,         // -0.05 .. +0.20
    pub word_spacing: f64,           // -0.10 .. +0.30
    pub margin_adjustment: f64,      // 0.0 .. 0.6
    pub has_custom_layout: bool,     // master toggle (gates the 4 sliders)
}
```

Leaf-level extras (font scale and dark variant are NOT on the theme — they're
on the leaf, because the user adjusts them in-flight) :

```rust
pub struct Leaf {
    // ...
    pub font_scale: f32,           // 1.0 = default, stepped via A- / A+
    pub theme_dark_variant: bool,  // sun/moon toggle
    pub theme_identifier: Option<String>, // FK to ReaderTheme
}
```

---

## 3. `ReadingSettingsViewModel` — main sheet

From `_TtC8BookEPUB24ReadingSettingsViewModel.h` :

```objc
@interface _TtC8BookEPUB24ReadingSettingsViewModel {
    Swift.Bool              _isVerticalText;
    Swift.Array<BookEPUB.BookThemeViewModel> _themes;   // grid items
    UIContentSizeCategory   _contentSizeCategory;       // system Dynamic Type
    BookEPUB.BookThemeType  _currentThemeType;
    BookEPUB.PageNavigationStyle _pageNavigationStyle;  // scroll vs page (book icon)
    Swift.Bool              _showContentSizeIndicators; // tick marks on slider
    Swift.Optional<Int>     _contentSizeIndicatorIndex; // currently-selected tick
    Swift.Int               _numberOfContentSizeIndicators;
    Swift.Bool              _canIncreaseContentSize;    // A+ enabled
    Swift.Bool              _canDecreaseContentSize;    // A- enabled
    BookEPUB.FontDownloadAlert _fontDownloadAlert;
}
```

**Key insight #2** — Apple's text-size control is **stepped**, not a
continuous slider. The number of steps is variable (`numberOfContentSizeIndicators`)
and tied to `UIContentSizeCategory` (12 native levels). The `A` small / `A`
large buttons increment/decrement `contentSizeIndicatorIndex` ; the buttons
disable at the ends.

For Pinkha : map our `Leaf.font_scale` to 12 discrete steps mirroring
UIContentSizeCategory, OR simpler — 7 steps (0.7, 0.85, 1.0, 1.15, 1.3,
1.45, 1.6) since we don't ship a per-system Dynamic-Type pipeline yet.

---

## 4. `ThemeOptionsViewModel` — "Personnaliser le thème" sub-sheet

From `_TtC8BookEPUB21ThemeOptionsViewModel.h` :

```objc
@interface _TtC8BookEPUB21ThemeOptionsViewModel {
    Swift.Optional<String>  previewText;             // dummy text in preview
    BookEPUB.BookThemeEntity originalTheme;          // for "Reset" button
    BookEPUB.BookEntityType  bookEntity;
    Swift.Bool               isVerticalText;
    BookLayoutMode           layoutMode;
    Combine.Published<(BookThemeEntity, BEContentCleanupJSOptions)> _themeAndCleanupOptions;
    Combine.Published<CGFloat>             _textZoomFactor;
    Combine.Published<UIContentSizeCategory> _sizeCategory;
    Combine.Published<Int>                 _columnCount;
    Combine.Published<EditingState>        _editingState;
    Combine.Published<Array<ThemeFontViewModel>> _fonts;
    Combine.Published<FontDownloadAlert>   _fontDownloadAlert;
    BookContentLayoutProviding             contentLayoutProvider;
}
```

**Key insight #3** — All settings are **Combine.Published**, so the live
preview at the top of the sheet subscribes to each one and re-renders on
any change. There's a single `originalTheme` snapshot so the user can
discard changes (`Reset Theme` button).

---

## 5. `BrightnessController` — sun-slider

From `_TtC5Books20BrightnessController.h` :

```objc
@interface _TtC5Books20BrightnessController {
    UIScreen        screen;
    AnyCancellable? subscription;            // observes brightness changes
    CGFloat         _brightness;
    Observation.Registrar _$observationRegistrar;
}
```

**Key insight #4** — Apple **overrides** `UIScreen.brightness` directly
(not a local dimming overlay). They subscribe to brightness-change
notifications via Combine so external changes (Control Center, hardware
key) update the slider in real-time. They do NOT restore the original
brightness on dismiss — the user's slider value persists as a system-wide
preference for the reader.

For Pinkha : we should restore on dismiss (the user might not want a notes
app to permanently dim their screen). Snapshot `UIScreen.main.brightness`
on sheet appear, restore on disappear.

---

## 6. Exact French strings (from `Localizable.loctable`)

Extracted from `Books.app/Localizable.loctable` (main app strings) and
`Books.app/Frameworks/BookEPUB.framework/Localizable.loctable` (reader
strings). Both verified on iOS 26.5.1.

| English | French |
|---------|--------|
| `Themes & Settings` | **Thèmes et réglages** |
| `Customize` | **Personnaliser** |
| `Customize_Theme_Title` | **Personnaliser le thème** |
| `Customize_Theme_Button` | **Personnaliser le thème** |
| `Reset Theme` | **Réinitialiser le thème** |
| `Reset theme options` | **Réinitialiser les options du thème** |
| `Discard theme unsaved changes?` | **Annuler les modifications du thème non enregistrées ?** |
| `Theme preview` | **Aperçu du thème** |
| `Brightness` | **Luminosité** |
| `Increase Brightness` | **Augmenter la luminosité** |
| `Decrease Brightness` | **Réduire la luminosité** |
| `Font Size` | **Taille de la police** |
| `Increase Font Size` | **Augmenter la taille de la police** |
| `Decrease Font Size` | **Diminuer la taille de la police** |
| `Reset Font Size to Default` | **Rétablir la taille de police par défaut** |
| `Font` | **Police** |
| `Bold` | **Gras** |
| `Bold Text` | **Gras** |
| `Justify Text` | **Justifier le texte** |
| `LINE SPACING` | **ESPACEMENT DES LIGNES** |
| `CHARACTER SPACING` | **ESPACEMENT DES CARACTÈRES** |
| `WORD SPACING` | **ESPACEMENT DES MOTS** |
| `MARGINS` | **MARGES** |
| `Accessibility & Layout Options` | **Accessibilité et options de présentation** |
| `Light Theme` | **Thème clair** |
| `Dark Theme` | **Thème sombre** |
| `Original Theme` | **Thème Original** |
| `Quiet Theme` | **Thème Tranquille** |
| `Paper Theme` | **Thème Papier** |
| `Bold Theme` | **Thème Gras** |
| `Calm Theme` | **Thème Calme** |
| `Focus Theme` | **Thème Attention** |
| `Theme_Customized` | **Personnalisé** |
| `Open customize theme menu` | **Ouvrir le menu de personnalisation du thème** |
| `Appearance or theme to change to` | **Apparence ou thème de remplacement** |

Theme names without the "Theme/Mode" suffix :

| English | French |
|---------|--------|
| Original | **Original** |
| Quiet | **Tranquille** |
| Paper | **Papier** |
| Bold | **Gras** |
| Calm | **Calme** |
| Focus | **Attention** |

---

## 7. CSS user stylesheets

Apple ships three CSS files in the EPUB framework that drive the actual
text rendering — useful reference for our own typography defaults :

```
Books.app/Frameworks/BookEPUB.framework/
├── user_stylesheet_flowable.css      ← base flow rules
├── user_stylesheet_colors_light.css  ← light-variant colors per theme
└── user_stylesheet_colors_dark.css   ← dark-variant colors per theme
```

Worth reading these to crib the exact hex colors Apple uses for each
named theme (Original / Tranquille / Papier / Gras / Calme / Attention).

---

## 8. Implications for Pinkha (PRO-62)

1. **Two sheets, not one** :
   - Main sheet : font-stepper + theme grid + brightness + appearance toggle
   - Sub-sheet : "Personnaliser le thème" with live preview + sliders
2. **Per-theme typography** (not per-leaf) for the 7 sliders/toggles, mirroring
   Apple's `BookTheme` model. Per-leaf only for `font_scale`, `theme_identifier`,
   and `theme_dark_variant`.
3. **Stepped font-size**, not continuous — A- / A+ buttons with discrete
   levels and disable-at-bounds.
4. **Live preview** updates via state observation on every slider change.
5. **Originate snapshot** for the Reset Theme button.
6. **Brightness via `UIScreen.main.brightness`** — but restore on dismiss
   (deviation from Apple, since we're a notes app, not a reader app).
7. Use **exact Apple French strings** in Localizable.xcstrings (table above).

---

## 9. Reproduction steps (for future RE)

Source IPSW : `~/Library/Mobile Documents/com~apple~CloudDocs/~ Projectground — iCloud/Doneground/pinkha-app/ipsw_extract/`

```bash
# DMGs were already decrypted (.dmg files alongside the .aea wrappers).
cd ~/.../pinkha-app/

hdiutil attach -nobrowse -readonly ipsw_extract/23F81__iPhone18,1/094-55036-101.dmg
# → /Volumes/LuckF23F81.V53OS

# Class-dump each framework :
for fw in BlissReader BookCore BooksAll BookEPUB BookStoreUI BooksUI TemplateUI; do
  ipsw class-dump --headers \
    --output safari_re/books_extracts/headers/$fw \
    "/Volumes/LuckF23F81.V53OS/private/var/staged_system_apps/Books.app/Frameworks/$fw.framework/$fw"
done
# Main binary :
ipsw class-dump --headers --output safari_re/books_extracts/headers/Books \
    "/Volumes/LuckF23F81.V53OS/private/var/staged_system_apps/Books.app/Books"

# Strings :
plutil -convert json -o /tmp/books-app-loc.json \
    "/Volumes/LuckF23F81.V53OS/private/var/staged_system_apps/Books.app/Localizable.loctable"

# Cleanup :
hdiutil detach /Volumes/LuckF23F81.V53OS
hdiutil detach /Volumes/LuckF23F81.V53SystemCryptex
```

Total time : ~3 min (DMG already decrypted) ; ~30 min if starting from .aea.

---

## 10. Génération iOS 27 — extraction depuis macOS 27 (2026-08-06)

iOS 27 n'est pas encore public : le dernier IPSW téléchargeable pour
iPhone18,1 est **26.6**. Mais `Books.app` de **macOS 27.0** embarque les mêmes
frameworks (`BookEPUB`, `BookCore`, `BlissReader`, `BooksUI`) et c'est la même
génération de code — donc aucune raison de télécharger 11 Go.

Source : `/System/Applications/Books.app` (Books v9, macOS 27.0).

### 10.1 Modèle de données réel (`BookTheme.momd`, version 6)

Les attributs persistés par Apple, extraits du modèle Core Data :

```
identifier · fontsByLanguage [String:String] · lineHeight · letterSpacing
wordSpacing · isFontBolded · justify · hasCustomLayout · marginAdjustment
allowsMultipleColumns · multipleColumnMode
```

> **Aucune couleur n'est persistée.** Elles sont dérivées de l'identifiant
> dans le code — c'est pourquoi les CSS (`user_stylesheet_colors_*.css`) ne
> contiennent que des `var(--background-color)` : les valeurs sont injectées à
> l'exécution.

### 10.2 Les six thèmes, dans l'ordre de l'enum

Ordre **confirmé par la disposition mémoire** des chaînes dans le binaire
(offsets contigus 2702748 → 2702779), pas déduit :

```
0 original · 1 quiet · 2 paper · 3 bold · 4 calm · 5 focus
```

Ce qui correspond exactement à l'ordre de `AppSettings.Theme` côté pinkha
(original, tranquille, papier, gras, calme, attention).

### 10.3 Couleurs de fond exactes

Extraites de `BookEPUB.BookThemeEntity.backgroundColor.getter` en émulant
l'arbre de branchement sur (index du thème, variante sombre). Les valeurs
sont des immédiats IEEE-754 construits en `mov`/`movk` puis `fmov`.

| # | Apple | pinkha | Clair | Sombre |
| --- | --- | --- | --- | --- |
| 0 | `original` | `original` | `#FFFFFF` | `#000000` |
| 1 | `quiet` | `tranquille` | `#4A4A4D` | `#000000` |
| 2 | `paper` | `papier` | `#EEEDED` | `#1C1C1E` |
| 3 | `bold` | `gras` | `#FFFFFF` | `#000000` |
| 4 | `calm` | `calme` | `#F1E2C9` | `#423B30` |
| 5 | `focus` | `attention` | `#FFFCF4` | `#18160C` |

Écarts avec ce que pinkha rendait avant cette extraction : Tranquille était
`#1C1C1C` au lieu de `#4A4A4D`, Papier `#F5F5F5` au lieu de `#EEEDED`, Calme
`#EDE0C7` au lieu de `#F1E2C9`, Attention `#FAF2DB` au lieu de `#FFFCF4`.

### 10.4 Surface de couleurs de `BookThemeEntity`

Bien plus riche que le couple fond/texte de pinkha :

```
backgroundColor · primaryLabelColor · secondaryLabelColor
primaryLabel · secondaryLabel · tertiaryLabel · themeSeparatorColor
ButtonStyle.fill · ButtonStyle.label · ProgressStyle.tint
```

### 10.5 Libellés exacts

| Clé | EN | FR |
| --- | --- | --- |
| `Themes & Settings` | Themes & Settings | Thèmes et réglages |
| `Theme` | Theme | Thème |
| `Themes` | Themes | Thèmes |
| `Appearance` | Appearance | Apparence |
| `Brightness` | Brightness | Luminosité |
| `Font` | Font | Police |
| `Font Size` | Font Size | Taille de la police |
| `Customize_Theme_Button` | Customize Theme | Personnaliser le thème |
| `Customize_Theme_Title` | Customize Theme | Personnaliser le thème |
| `Reset Theme` | Reset Theme | Réinitialiser le thème |
| `Reset` | Reset | Réinitialiser |
| `Reset Text Size` | Reset Text Size | Réinitialiser la taille du texte |
| `LINE SPACING` | LINE SPACING | ESPACEMENT DES LIGNES |
| `CHARACTER SPACING` | CHARACTER SPACING | ESPACEMENT DES CARACTÈRES |
| `WORD SPACING` | WORD SPACING | ESPACEMENT DES MOTS |
| `MARGINS` | MARGINS | MARGES |
| `Columns` | Columns | Colonnes |
| `Justify Text` | Justify Text | Justifier le texte |
| `Bold Text` | Bold Text | Gras |
| `Allow Multiple Columns` | Allow Multiple Columns | Autoriser les colonnes multiples |
| `Theme preview` | Theme preview | Aperçu du thème |
| `Theme Settings` | Theme Settings | Réglages du thème |
| `Discard theme unsaved changes?` | Discard theme unsaved changes? | Annuler les modifications du thème non enregistrées ? |
| `Original Theme` | Original Theme | Thème Original |
| `Quiet Theme` | Quiet Theme | Thème Tranquille |
| `Paper Theme` | Paper Theme | Thème Papier |
| `Bold Theme` | Bold Theme | Thème Gras |
| `Calm Theme` | Calm Theme | Thème Calme |
| `Focus Theme` | Focus Theme | Thème Attention |
| `Increase Font Size` | Increase Font Size | Augmenter la taille de la police |
| `Decrease Font Size` | Decrease Font Size | Diminuer la taille de la police |
| `Increase Brightness` | Increase Brightness | Augmenter la luminosité |
| `Decrease Brightness` | Decrease Brightness | Réduire la luminosité |

### 10.6 Méthode reproductible

```bash
B=/System/Applications/Books.app/Contents/Frameworks/BookEPUB.framework/Versions/A/BookEPUB

# Les symboles Swift utilisent une substitution : chercher "BookThemeEntity"
# échoue, le nom mangué est `_$s8BookEPUB0A11ThemeEntityV...`.
nm -a "$B" | grep -oE '_\$s[A-Za-z0-9_$]+' | sort -u | while read s; do
  echo "$s|$(xcrun swift-demangle -compact "$s")"; done | grep -i color

# Libellés :
plutil -convert json -o loc.json /System/Applications/Books.app/Contents/Resources/Localizable.loctable
```

Le script d'émulation du graphe de branchement est dans `/tmp/books_re/extract.py`
au moment de l'extraction ; sa logique est décrite en 10.3.

### 10.7 Ce que cette méthode ne donne PAS

Les sheets sont en **SwiftUI** : paddings, marges, tailles et rayons sont
compilés dans du code de layout, pas stockés en ressources. Aucun `.nib`, aucun
plist de géométrie. Une copie au pixel près exige donc de **mesurer des
captures d'écran** de l'app réelle — le binaire ne les livrera pas.

### 10.8 Ne pas embarquer les polices d'Apple

`Canela`, `Publico` et `Proxima Nova` sont des polices commerciales
sous licence Apple, pas sous la nôtre. Extraire les specs (noms, tailles,
graisses) est une chose ; embarquer les fichiers en est une autre, et le dépôt
est public. Utiliser des équivalents système ou libres.

### 10.9 Valeurs typographiques par défaut, par thème

Extraites de `BookEPUB.BookThemeEntity.defaultOverrides.getter`. Interlignes
confirmés (immédiats IEEE-754) :

| # | thème | `lineHeight` |
| --- | --- | --- |
| 0 | `original` | 1.2 |
| 1 | `quiet` | 1.4 |
| 2 | `paper` | 1.55 |
| 3 | `bold` | 1.5 |
| 4 | `calm` | 1.55 |
| 5 | `focus` | 1.4 |

Le défaut global du getter est 1.4 — c'est la valeur que reçoivent `quiet` et
`focus`, qui n'ont pas de branche propre.

La structure `Overrides` écrite en sortie, avec les offsets observés :

```
+0x00  tableau (fontsByLanguage — vide par défaut)
+0x08  (w20 == 3)              → vrai pour `bold` seul   ⇒ isFontBolded
+0x09  (w20 != 0)              → vrai sauf `original`
+0x10  double                  ⇒ lineHeight (table ci-dessus)
+0x18  0                       ⇒ letterSpacing
+0x20  0                       ⇒ wordSpacing
+0x28  (w20 - 5) <u 3          → vrai pour `focus` seul
+0x29  1                       (constant)
+0x30  0
```

> ⚠️ Les **valeurs** sont lues directement dans le code ; les **noms** de champs
> aux offsets 0x08 / 0x09 / 0x28 / 0x29 sont déduits de leur sémantique
> (« vrai pour bold seul » ⇒ gras) et de l'ordre des attributs Core Data. À
> confirmer avant de s'appuyer dessus pour autre chose que les valeurs.
