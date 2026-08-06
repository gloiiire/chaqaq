import SwiftUI
import PinkhaCore
import PinkhaFFI

// ── Reader settings sheet (PRO-62) ───────────────────────────────────────────
//
// "Thèmes et réglages" — single sheet that gathers font-size, light/dark
// appearance toggle, brightness, and the visual theme grid. Replaces the
// inline theme submenu buried in the overflow menu.
//
// Scaffolded 2026-06-26. State wiring + Rust `Leaf.font_scale` + dark
// variants + brightness override land in follow-up commits on this same
// branch.

// MARK: - Mesures relevées sur Books

/// Géométrie du sheet « Thèmes et réglages », mesurée au pixel sur une capture
/// native iPhone 17 Pro (1206×2622 px, écran 3×, soit 402×874 pt).
///
/// Ces valeurs remplacent des littéraux choisis à l'œil qui traînaient un peu
/// partout dans ce fichier — 16 pt de padding horizontal là où Books en met
/// 28,7, 10 pt entre les rangées là où il en met 16. Les regrouper ici rend
/// chaque écart au modèle visible et corrigeable en un point.
///
/// Détail et méthode : `utilities/docs/BOOKS-READER-SETTINGS-RE.md` §11.
enum BooksSheetMetrics {
    /// Marge du sheet aux bords de l'écran. Ce sheet **flotte** ; celui de
    /// personnalisation est pleine largeur — les deux ne partagent pas de
    /// conteneur.
    static let sheetSideMargin: CGFloat = 8
    /// Padding intérieur, du bord du sheet au contenu.
    ///
    /// Recoupé plutôt que pris pour argent comptant : largeur intérieure
    /// 385,7 − 2×28,7 = 328,3, contre une grille occupant 3×102,3 + 2×10 =
    /// 326,9. Les deux concordent à la précision de mesure.
    static let contentPadding: CGFloat = 28.7
    /// Hauteur des deux capsules de contrôle (A−/A+ et défilement/apparence).
    static let capsuleHeight: CGFloat = 46
    /// Écart entre les deux capsules, et entre les colonnes de la grille.
    static let horizontalGap: CGFloat = 10
    /// Écart entre les deux rangées de tuiles. Volontairement différent de
    /// l'écart horizontal — Books n'utilise pas une grille isotrope.
    static let gridRowGap: CGFloat = 16
    /// Hauteur d'une tuile de thème. La largeur découle du padding et de
    /// l'écart, donc on ne la fixe pas.
    static let tileHeight: CGFloat = 89.3
    /// Rayon de coin d'une tuile : la largeur pleine est atteinte ~18 pt sous
    /// le bord supérieur.
    static let tileCornerRadius: CGFloat = 18
    /// Hauteur du bouton « Personnaliser », pleine largeur intérieure.
    static let personnaliserHeight: CGFloat = 54.7
}

public struct ReaderSettingsSheet: View {

    // ── Bindings to leaf state ────────────────────────────────────────────

    /// Current theme key (e.g. "tranquille") — nil means "follow app
    /// settings". Updated immediately on tile tap.
    @Binding var theme: String?
    /// Per-leaf font scale (1.0 = default). Persisted in Rust via the
    /// leaf view-model once the FFI is in place.
    @Binding var fontScale: Double
    /// Local override of system brightness while the sheet is open.
    /// Restored on dismiss. Hooks `UIScreen.main.brightness`.
    @Binding var brightness: Double
    /// 5-way appearance choice (Light / Dark / Match Device / Match
    /// Surroundings / Match Settings). Persists to Rust via
    /// `LeafReaderSettings.themeAppearance`. Resolved down to a Bool
    /// at render time via `effectiveDark(systemIsDark:settingsIsDark:)`.
    @Binding var appearance: ReaderAppearance
    /// True when the device's current `UITraitCollection` reports a
    /// dark `userInterfaceStyle`. Passed in so the sheet can resolve
    /// the `.system` / `.ambient` options without reading the trait
    /// itself (which is fragile under SwiftUI's `.preferredColorScheme`
    /// overrides — the parent uses the raw UIKit value).
    let systemIsDark: Bool
    /// Current value of the app-wide `AppSettings.themeDarkVariant`.
    /// Used to resolve the `.settings` option.
    let settingsIsDark: Bool
    /// Best-effort ambient dark from `AmbientLight` (brightness <
    /// threshold). Used to resolve the `.ambient` option.
    let ambientIsDark: Bool

    /// Available themes to display in the grid. Each entry knows how
    /// to render its own `Aa` preview tile.
    let themeOptions: [ReaderThemeOption]
    /// Min / max bounds for the font-scale stepper.
    let fontScaleRange: ClosedRange<Double>
    /// Discrete steps inside the stepper.
    let fontScaleStep: Double

    /// User tapped "Personnaliser" — opens the deeper customization
    /// sheet (font family, line spacing…). Out of scope for v1.
    let onPersonnaliser: () -> Void
    /// User tapped the close button.
    let onClose: () -> Void

    /// Computed light/dark used by the theme tile previews — collapses
    /// the 5-way appearance choice down to the binary the rendering
    /// code understands. Kept private to the sheet : callers always
    /// pass the enum + ambient scalars and let the sheet do the math.
    private var isDarkVariant: Bool {
        appearance.effectiveDark(
            systemIsDark: systemIsDark,
            settingsIsDark: settingsIsDark,
            ambientIsDark: ambientIsDark
        )
    }

    public init(
        theme: Binding<String?>,
        fontScale: Binding<Double>,
        brightness: Binding<Double>,
        appearance: Binding<ReaderAppearance>,
        systemIsDark: Bool,
        settingsIsDark: Bool,
        ambientIsDark: Bool,
        themeOptions: [ReaderThemeOption],
        fontScaleRange: ClosedRange<Double> = 0.7...1.6,
        fontScaleStep: Double = 0.1,
        onPersonnaliser: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self._theme = theme
        self._fontScale = fontScale
        self._brightness = brightness
        self._appearance = appearance
        self.systemIsDark = systemIsDark
        self.settingsIsDark = settingsIsDark
        self.ambientIsDark = ambientIsDark
        self.themeOptions = themeOptions
        self.fontScaleRange = fontScaleRange
        self.fontScaleStep = fontScaleStep
        self.onPersonnaliser = onPersonnaliser
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            controlsStrip
                .padding(.horizontal, BooksSheetMetrics.contentPadding)
                .padding(.top, 10)
            brightnessSlider
                .padding(.horizontal, BooksSheetMetrics.contentPadding)
                .padding(.top, 14)
                .padding(.bottom, 14)

            // Theme grid section sits on a slightly distinct backdrop
            // (Apple Books pattern : top half rides the bare glass,
            // grid half has a faint tonal tint so the two regions read
            // as separate without the seam looking like a hard divider).
            VStack(spacing: 0) {
                themeGrid
                    .padding(.horizontal, BooksSheetMetrics.contentPadding)
                    .padding(.top, 14)
                    .padding(.bottom, 7)
                personnaliserButton
                    .padding(.horizontal, BooksSheetMetrics.contentPadding)
                    .padding(.bottom, 25.7)
            }
            .frame(maxWidth: .infinity)
            // Apple Books shows a clear horizontal seam between the
            // two regions — visible in BOTH light and dark, regardless
            // of the leaf's bg colour bleeding through.
            //
            // Material layering alone (thinMaterial + regularMaterial)
            // doesn't generate enough contrast over a dark leaf — both
            // regions just look like the same tinted blur. We get the
            // step by stacking a TINT that flips direction with the
            // colour scheme :
            //   • light : darken by ~8 %  (bottom darker than top)
            //   • dark  : lighten by ~22 % (bottom clearly lighter)
            // Apple Books pushes the dark-mode lift pretty hard — the
            // bottom reads as a medium grey, not a barely-lifted near-
            // black. Sample-matched against the Books reader sheet on
            // device 2026-06-27.
            .background(.regularMaterial)
            .background(
                Color(uiColor: UIColor { trait in
                    trait.userInterfaceStyle == .dark
                        ? UIColor.white.withAlphaComponent(0.70)
                        : UIColor.black.withAlphaComponent(0.08)
                })
            )
        }
        // No opaque outer background — the sheet's
        // `.presentationBackground(.thinMaterial)` modifier provides
        // the glass. Painting a solid color here would defeat it.
    }

    // ── Header ────────────────────────────────────────────────────────────

    private var header: some View {
        HStack(alignment: .center) {
            // Apple-exact FR string "Thèmes et réglages" comes from
            // Localizable.xcstrings via this LocalizedStringKey.
            Text("Themes & Settings")
                .font(.title2.weight(.bold))
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            // Liquid Glass close button — same vocabulary as the X in
            // `CreateLeafSheet` and `AllLeavesSwitcher`. `.regular`
            // glass keeps it readable over the dark sheet bg, and
            // `.interactive()` opts into the iOS 26 ripple/dim tap
            // animation (the one SwiftUI's `.plain` button style
            // strips out).
            Button {
                Haptic.tap()
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, BooksSheetMetrics.contentPadding)
        // Tight but ascender-safe top spacing — Apple Books leaves
        // ~28 pt between sheet-top and the bold title baseline.
        .padding(.top, 28)
    }

    // ── Controls strip : font size + appearance toggle ────────────────────

    private var controlsStrip: some View {
        HStack(spacing: 10) {
            fontSizeStepper
                .layoutPriority(1)
            appearanceToggle
                .frame(width: 76)
        }
    }

    /// Two-button stepper rendering small `A` and large `A` ; tapping
    /// either nudges `fontScale` by ±`fontScaleStep` clamped to
    /// `fontScaleRange`. Apple-Books pattern : the buttons disable at
    /// the bounds (the model exposes `canIncreaseContentSize` /
    /// `canDecreaseContentSize` for that ; here we infer from the
    /// clamped range).
    private var fontSizeStepper: some View {
        HStack(spacing: 0) {
            stepperButton(
                label: "A",
                size: 15,
                disabled: fontScale <= fontScaleRange.lowerBound + 0.001,
                accessibility: "Decrease Font Size"
            ) {
                fontScale = max(fontScaleRange.lowerBound, fontScale - fontScaleStep)
            }
            Rectangle()
                .fill(Color.primary.opacity(0.18))
                .frame(width: 1, height: 22)
            stepperButton(
                label: "A",
                size: 24,
                disabled: fontScale >= fontScaleRange.upperBound - 0.001,
                accessibility: "Increase Font Size"
            ) {
                fontScale = min(fontScaleRange.upperBound, fontScale + fontScaleStep)
            }
        }
        .frame(height: BooksSheetMetrics.capsuleHeight)
        .background(Capsule().fill(Color(.tertiarySystemFill)))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func stepperButton(label: String,
                               size: CGFloat,
                               disabled: Bool,
                               accessibility: LocalizedStringKey,
                               action: @escaping () -> Void) -> some View {
        Button {
            Haptic.tap()
            action()
        } label: {
            Text(label)
                .font(.system(size: size, weight: .regular))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(disabled ? .secondary : .primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(SoftPressButtonStyle())
        .disabled(disabled)
        .accessibilityLabel(accessibility)
    }

    /// Appearance popover — mirrors Apple Books' 4-option menu and
    /// adds a 5th, pinkha-specific row ("Suivre les réglages") that
    /// follows the app-wide `AppSettings.themeDarkVariant`.
    ///
    /// Uses an inline `Picker` instead of bare `Button` rows : a
    /// Picker inside a Menu is the only SwiftUI shape that auto-
    /// renders the leading checkmark on the selected row (the look
    /// Apple Books uses). We keep `.menuOrder(.fixed)` so the rows
    /// stay in our authored order (Light → Settings) instead of
    /// being reshuffled around the selection.
    ///
    /// The pill icon mirrors the *resolved* dark/light state so a
    /// user who picked "Suivre les réglages" still sees a sun or
    /// moon depending on what the global toggle currently is.
    private var appearanceToggle: some View {
        Menu {
            // Top group : the 4 user-facing modes (Light / Dark /
            // Match Settings / Match Surroundings). Split into a
            // separate Picker so we can drop a Divider before the
            // last "Match Device" row — same layout Apple Books uses
            // for the appearance popover.
            Picker(selection: $appearance) {
                ForEach(appearanceMenuOptionsTop, id: \.mode) { entry in
                    Label(entry.titleKey, systemImage: entry.symbol)
                        .tag(entry.mode)
                }
            } label: {
                Text("Theme Appearance")
            }
            .pickerStyle(.inline)

            Divider()

            // Bottom group : a single row, "Identique à l'appareil".
            // SwiftUI shows the checkmark on whichever Picker holds
            // the currently-selected tag, so the two pickers share
            // the same `$appearance` binding without conflict.
            Picker(selection: $appearance) {
                ForEach(appearanceMenuOptionsBottom, id: \.mode) { entry in
                    Label(entry.titleKey, systemImage: entry.symbol)
                        .tag(entry.mode)
                }
            } label: {
                Text("Theme Appearance")
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: isDarkVariant ? "moon.stars.fill" : "sun.horizon.fill")
                .font(.system(size: 18, weight: .regular))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .frame(height: BooksSheetMetrics.capsuleHeight)
        .background(Capsule().fill(Color(.tertiarySystemFill)))
        .clipShape(Capsule())
        .foregroundStyle(.primary)
        .accessibilityLabel("Theme Appearance")
        .accessibilityValue(Text(currentAppearanceLabel))
        .onChange(of: appearance) { _, _ in Haptic.tap() }
    }

    /// Static row spec for the appearance menu. Holds the icon (SF
    /// Symbol matched 1:1 with Apple Books' Bookshelf icons) and the
    /// localized `LocalizedStringKey` so xcstrings catches each row.
    /// Order matters — `.menuOrder(.fixed)` above preserves it.
    private struct AppearanceMenuEntry {
        let mode: ReaderAppearance
        let titleKey: LocalizedStringKey
        let symbol: String
    }

    /// Top group of the appearance menu — 4 rows, ordered like Apple
    /// Books with the pinkha-specific "Match Settings" row inserted
    /// after Dark (it's the per-app preference users will reach for
    /// most often, so it sits with the explicit choices).
    private var appearanceMenuOptionsTop: [AppearanceMenuEntry] {
        [
            .init(mode: .light,    titleKey: "Light",              symbol: "sun.horizon.fill"),
            .init(mode: .dark,     titleKey: "Dark",               symbol: "moon.stars.fill"),
            .init(mode: .ambient,  titleKey: "Match Surroundings", symbol: "sun.dust.fill"),
            .init(mode: .settings, titleKey: "Match Settings",     symbol: "gear"),
        ]
    }

    /// Bottom group — single row, separated by a divider. "Match
    /// Device" is the system-level fallback ; isolating it visually
    /// signals it as the "follow whatever the OS does" escape hatch.
    private var appearanceMenuOptionsBottom: [AppearanceMenuEntry] {
        [
            .init(mode: .system,   titleKey: "Match Device",       symbol: "circle.lefthalf.filled"),
        ]
    }

    /// Accessibility label describing the currently selected mode —
    /// distinct from the resolved dark/light Bool so VoiceOver users
    /// hear "Match Settings" instead of "Light" when the global
    /// toggle happens to be light.
    private var currentAppearanceLabel: String {
        switch appearance {
        case .light:    return "Light"
        case .dark:     return "Dark"
        case .system:   return "Match Device"
        case .ambient:  return "Match Surroundings"
        case .settings: return "Match Settings"
        }
    }

    // ── Brightness slider ─────────────────────────────────────────────────

    private var brightnessSlider: some View {
        HStack(spacing: 14) {
            Image(systemName: "sun.min.fill")
                .foregroundStyle(.primary.opacity(0.55))
                .font(.system(size: 16, weight: .regular))
            Slider(value: $brightness, in: 0...1)
                .tint(Color.primary.opacity(0.85))
            Image(systemName: "sun.max.fill")
                .foregroundStyle(.primary.opacity(0.55))
                .font(.system(size: 20, weight: .regular))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Brightness")
    }

    // ── Theme grid ────────────────────────────────────────────────────────

    private let gridColumns = Array(
        repeating: GridItem(.flexible(), spacing: BooksSheetMetrics.horizontalGap),
        count: 3
    )

    private var themeGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: BooksSheetMetrics.gridRowGap) {
            ForEach(themeOptions) { option in
                ThemeTile(
                    option: option,
                    isSelected: option.key == theme,
                    isDarkVariant: isDarkVariant
                ) {
                    Haptic.tap()
                    theme = option.key
                }
            }
        }
    }

    // ── Personnaliser ─────────────────────────────────────────────────────

    private var personnaliserButton: some View {
        Button {
            Haptic.tap()
            onPersonnaliser()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "gear")
                    .font(.system(size: 17, weight: .regular))
                Text("Customize")
                    .font(.system(size: 17, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: BooksSheetMetrics.personnaliserHeight)
            .background(Capsule().fill(Color(.tertiarySystemFill)))
        }
        .buttonStyle(SoftPressButtonStyle())
        .foregroundStyle(.primary)
        .accessibilityLabel("Customize Theme")
    }
}

// ── Theme option model + tile ────────────────────────────────────────────────

/// Description of one entry in the theme grid. The view-model layer
/// builds an array of these from `AppSettings.Theme` once dark variants
/// are added. Kept here as a value type so the sheet stays pure SwiftUI
/// and easy to preview / snapshot-test.
public struct ReaderThemeOption: Identifiable, Equatable {
    public let id: String
    /// Persistent key written back to `Leaf.theme` (e.g. "tranquille").
    /// `nil`-themed leaves match the entry with `key == nil`.
    public let key: String?
    /// Display name (already localized) shown under the `Aa`.
    public let label: String
    /// Background color of the tile preview, for the light variant.
    public let lightBackground: Color
    /// Foreground (Aa) color, for the light variant.
    public let lightForeground: Color
    /// Background color of the tile preview, for the dark variant.
    /// Pass the same value as `lightBackground` if the theme has no
    /// distinct dark variant yet — the asterisk marker will simply
    /// not be shown.
    public let darkBackground: Color
    public let darkForeground: Color
    /// True if this theme has a meaningfully different dark variant.
    /// Drives the `*` corner marker on the tile.
    public let hasDarkVariant: Bool
    /// Family name of the font used to render this theme's content
    /// (and the `Aa` + label in the grid tile). Mirrors Apple Books'
    /// per-theme typography — verified font families hardcoded in
    /// `BookEPUB` binary + iOS-bundled serifs (Iowan Old Style,
    /// Athelas). Pass `nil` for the system font.
    public let fontFamily: String?
    /// True if the theme's preview Aa should be rendered bold (used
    /// by the Bold theme variant where the typeface itself is heavy).
    public let isPreviewBold: Bool
    /// True if the tile preview should slant the Aa + label into
    /// italic — Apple Books does this for Tranquille and Calme to
    /// give those tiles a distinctive feel.
    public let isPreviewItalic: Bool

    public init(
        key: String?,
        label: String,
        lightBackground: Color,
        lightForeground: Color,
        darkBackground: Color,
        darkForeground: Color,
        hasDarkVariant: Bool,
        fontFamily: String? = nil,
        isPreviewBold: Bool = false,
        isPreviewItalic: Bool = false
    ) {
        self.id = key ?? "__default__"
        self.key = key
        self.label = label
        self.lightBackground = lightBackground
        self.lightForeground = lightForeground
        self.darkBackground = darkBackground
        self.darkForeground = darkForeground
        self.hasDarkVariant = hasDarkVariant
        self.fontFamily = fontFamily
        self.isPreviewBold = isPreviewBold
        self.isPreviewItalic = isPreviewItalic
    }

    /// SwiftUI `Font` resolved for the tile's `Aa` glyph at a given
    /// point size. Resolves Publico via a fallback chain (iOS exposes
    /// it under different PostScript names depending on system bundles),
    /// then falls back to system if nothing matches.
    public func previewFont(size: CGFloat) -> Font {
        let weight: UIFont.Weight = isPreviewBold ? .bold : .regular
        let baseFont: UIFont = {
            // Publico / Canela live in bundled .ttc files — walk
            // the candidate chains so the tile preview matches the
            // actual leaf rendering (same lookup the theme uses).
            if fontFamily == "Publico" {
                for candidate in ["PublicoText-Roman", "Publico Text", "PublicoText",
                                  "Publico", "Publico-Text",
                                  ".AppleSystemUIFontSerif",
                                  "HoeflerText-Regular", "Hoefler Text"] {
                    if let f = UIFont(name: candidate, size: size) { return f }
                }
            } else if fontFamily == "Canela" {
                for candidate in ["CanelaText-Regular", "Canela Text", "CanelaText",
                                  "Canela-Regular", "Canela",
                                  "Palatino-Roman", "Palatino"] {
                    if let f = UIFont(name: candidate, size: size) { return f }
                }
            } else if fontFamily == "Proxima Nova" {
                for candidate in ["ProximaNova-Regular", "Proxima Nova", "ProximaNova",
                                  "AvenirNext-Regular", "Avenir Next"] {
                    if let f = UIFont(name: candidate, size: size) { return f }
                }
            } else if let family = fontFamily, let f = UIFont(name: family, size: size) {
                return f
            }
            return UIFont.systemFont(ofSize: size, weight: isPreviewBold ? .heavy : .bold)
        }()
        var descriptor = baseFont.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight.rawValue]
        ])
        if isPreviewItalic, let italic = descriptor.withSymbolicTraits(.traitItalic) {
            descriptor = italic
        }
        return Font(UIFont(descriptor: descriptor, size: size))
    }
}

private struct ThemeTile: View {
    let option: ReaderThemeOption
    let isSelected: Bool
    let isDarkVariant: Bool
    let onTap: () -> Void

    /// True for Original — the "no override, follow system" theme.
    /// Its tile must reflect the user's TRUE system appearance
    /// (Settings.app), not the sheet's overridden colorScheme. So we
    /// read from `UIScreen.main.traitCollection` rather than letting
    /// `Color(.systemBackground)` be hijacked by the leaf's
    /// `.preferredColorScheme(...)` override.
    private var isFollowSystem: Bool { option.key == nil }

    private var systemIsDark: Bool {
        UIScreen.main.traitCollection.userInterfaceStyle == .dark
    }

    private var background: Color {
        if isFollowSystem {
            return systemIsDark ? Color(white: 0.08) : Color.white
        }
        return isDarkVariant ? option.darkBackground : option.lightBackground
    }
    private var foreground: Color {
        if isFollowSystem {
            return systemIsDark ? Color(white: 0.9) : Color(white: 0.1)
        }
        return isDarkVariant ? option.darkForeground : option.lightForeground
    }

    var body: some View {
        Button(action: onTap) {
            // Reserve a 4 pt gutter on every side so the outside
            // selection ring stroke doesn't get clipped by the grid
            // cell bounds (the ring sits OUTSIDE the tile fill at
            // padding(-3), so without this it'd touch the next tile).
            //
            // Apple Books does NOT show a "has dark variant" marker
            // (asterisk / dot / badge) on its theme tiles — only the
            // selection ring distinguishes the active tile. We used
            // to overlay `Text("*")` here ; removed to match.
            tileBody
                .padding(4)
        }
        .buttonStyle(SoftPressButtonStyle())
        .accessibilityLabel(Text(option.label))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var tileBody: some View {
        // Hauteur fixe, pas de ratio carré : Books fait ses tuiles
        // 102,3 × 89,3 pt, soit nettement plus larges que hautes. La
        // largeur découle du padding et de l'écart de colonnes, donc
        // seule la hauteur se pose ici.
        RoundedRectangle(cornerRadius: BooksSheetMetrics.tileCornerRadius, style: .continuous)
            .fill(background)
            .frame(height: BooksSheetMetrics.tileHeight)
            .overlay(
                VStack(spacing: 0) {
                    Text("Aa")
                        .font(option.previewFont(size: 30))
                    Text(option.label)
                        .font(option.previewFont(size: 13))
                        .padding(.top, -2)
                }
                .foregroundStyle(foreground)
            )
            .overlay(
                // Selection ring rendered OUTSIDE the tile with a
                // ~2 pt gap so it doesn't touch the fill. Apple Books
                // colors the ring with the theme's FOREGROUND so it
                // adapts to both light and dark variants — a white
                // border on a cream theme would clash.
                RoundedRectangle(cornerRadius: BooksSheetMetrics.tileCornerRadius + 2,
                                 style: .continuous)
                    .strokeBorder(
                        isSelected ? foreground : Color.clear,
                        lineWidth: 2.5
                    )
                    .padding(-3)
            )
    }
}

#Preview {
    StatefulPreviewWrapper(initialTheme: nil) { themeBinding, fontBinding, brightnessBinding, appearanceBinding in
        ReaderSettingsSheet(
            theme: themeBinding,
            fontScale: fontBinding,
            brightness: brightnessBinding,
            appearance: appearanceBinding,
            systemIsDark: false,
            settingsIsDark: false,
            ambientIsDark: false,
            themeOptions: ReaderThemeOption.all,
            onPersonnaliser: {},
            onClose: {}
        )
    }
}

// MARK: - Preview helpers

private struct StatefulPreviewWrapper<Content: View>: View {
    @State private var theme: String?
    @State private var fontScale: Double = 1.0
    @State private var brightness: Double = 0.6
    @State private var appearance: ReaderAppearance = .settings
    let content: (Binding<String?>, Binding<Double>, Binding<Double>, Binding<ReaderAppearance>) -> Content

    init(initialTheme: String?,
         @ViewBuilder _ content: @escaping (Binding<String?>, Binding<Double>, Binding<Double>, Binding<ReaderAppearance>) -> Content) {
        self._theme = State(initialValue: initialTheme)
        self.content = content
    }

    var body: some View {
        content($theme, $fontScale, $brightness, $appearance)
    }
}

extension ReaderThemeOption {
    /// The theme grid, derived from `AppSettings.Theme` — the same type
    /// that paints the leaf.
    ///
    /// This used to be a hand-written `previewSet` living next to the
    /// `#Preview`, and production read from it. The two drifted: the
    /// tiles showed Papier as cream `(0.93, 0.91, 0.86)` while a leaf
    /// actually rendered it grey `(0.96, 0.96, 0.96)`, Tranquille as
    /// `white: 0.18` against a real `0.11`, and Calme and Attention were
    /// off too. The picker was advertising colours the reader never
    /// used. Deriving removes the second source rather than resyncing
    /// it, so the tile cannot lie again.
    @MainActor public static var all: [ReaderThemeOption] {
        AppSettings.Theme.allCases.map(ReaderThemeOption.init(theme:))
    }

    /// Builds the tile for one theme.
    ///
    /// `.original` means "no override, follow the system", so its
    /// `backgroundColor` / `foregroundColor` are `nil` — the tile falls
    /// back to semantic colours that track the sheet's own colour
    /// scheme, which is exactly what the leaf does in that case.
    @MainActor public init(theme: AppSettings.Theme) {
        let light = theme.backgroundColor ?? Color(uiColor: .systemBackground)
        let lightText = theme.foregroundColor ?? Color(uiColor: .label)
        self.init(
            // `Leaf.theme` stores `nil` for "no override", not the
            // string "original" — the tile has to match that shape or
            // an untouched leaf would highlight no tile at all.
            key: theme == .original ? nil : theme.rawValue,
            // Deliberately not `theme.labelString`: that returns
            // "Match App Appearance", which is the wording for the
            // app-wide Settings row. In the reader grid Apple Books
            // calls this one "Original", and so do we.
            label: theme == .original
                ? String(localized: "Original")
                : theme.labelString,
            lightBackground: light,
            lightForeground: lightText,
            darkBackground: theme.darkBackgroundColor ?? light,
            darkForeground: theme.darkForegroundColor ?? lightText,
            hasDarkVariant: theme.hasDarkVariant,
            fontFamily: theme.fontFamily,
            isPreviewBold: theme.boldText,
            isPreviewItalic: false
        )
    }
}

// MARK: - Button style

/// Reusable press style that mirrors the feedback Apple uses on
/// circle close buttons / pill controls : light scale-down + dim on
/// press, spring back on release. SwiftUI's `.plain` style strips ALL
/// chrome, including the press animation — which is why our buttons
/// felt "dead" compared to Apple Books.
///
/// Tuned values : 0.92 scale + 0.6 opacity on press, snappy 0.2 s
/// spring on release. Slightly less aggressive than UIKit's default
/// (0.85 scale) because our glyphs are dense and bigger scale shifts
/// look like a glitch.
struct SoftPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
            .animation(
                .spring(response: 0.2, dampingFraction: 0.7),
                value: configuration.isPressed
            )
    }
}
