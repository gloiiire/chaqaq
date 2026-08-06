import SwiftUI
import PinkhaCore

// ── Customize theme sub-sheet (PRO-62) ───────────────────────────────────────
//
// "Personnaliser le thème" — opened from the main `ReaderSettingsSheet`
// via the bottom Personnaliser button. Layout mirrors Apple Books'
// `ThemeOptionsViewModel` surface (cf.
// `utilities/docs/BOOKS-READER-SETTINGS-RE.md`) :
//   • Header : X (discard) — title — ✓ (commit)
//   • Live preview (top ~30 %) rendered with every current setting
//   • "Texte" section : Police picker row + Gras toggle
//   • "Accessibilité et options de présentation" section : master
//     toggle gates 4 sliders (line / character / word spacing + margins)
//   • Justifier le texte toggle
//   • Reset Theme link (restores the snapshot taken on open)
//
// All state is currently SwiftUI-local — Rust persistence on
// `BookTheme`-mirror fields lands in a follow-up commit (PRO-62 step 5).

public struct ReaderThemeCustomizationSheet: View {

    // ── Live bindings ─────────────────────────────────────────────────────

    @Binding var fontFamily: String
    @Binding var bold: Bool
    @Binding var lineSpacing: Double     // 0.8 … 2.4 (default 1.4)
    @Binding var letterSpacing: Double   // -0.05 … +0.20 (default 0.0)
    @Binding var wordSpacing: Double     // -0.10 … +0.30 (default 0.0)
    @Binding var marginScale: Double     // 0.0 … 0.6 (default 0.0)
    @Binding var justify: Bool
    @Binding var customLayoutEnabled: Bool

    /// Plain-text sample rendered in the live preview. Apple Books
    /// uses the current book's actual prose ; we pass the leaf's
    /// title + first paragraphs. Falls back to the canned sample
    /// when the leaf is empty.
    let leafPreviewText: String
    /// True when the current settings differ from the theme's
    /// factory defaults — drives the Reset button's enabled state
    /// (Apple Books pattern : Reset is greyed out when there's
    /// nothing to revert).
    let canReset: Bool
    /// Background colour of the preview surface — same as the actual
    /// leaf background so the user sees the exact rendering they'll
    /// get on commit. Mirrors Apple Books' WKWebView preview which
    /// inherits the book's CSS body bg.
    let previewBackground: Color
    /// Foreground (text) colour matching the leaf rendering.
    let previewForeground: Color
    /// Font family from the active theme (Charter / Palatino / etc.),
    /// used when the user hasn't picked a custom font ("System" in
    /// the picker). Keeps the preview faithful to the leaf's actual
    /// rendering until the user explicitly overrides via the Font row.
    let themeFontFamily: String?
    /// Human-readable label shown on the right of the "Police" row.
    /// Uses the theme's display name (e.g. "Publico Text", "Canela
    /// Text", "San Francisco") when the user hasn't picked a custom
    /// font, else the custom font's name.
    let themeFontDisplayName: String

    let availableFonts: [String]
    let onCommit: () -> Void
    let onDiscard: () -> Void
    let onReset: () -> Void

    public init(
        fontFamily: Binding<String>,
        bold: Binding<Bool>,
        lineSpacing: Binding<Double>,
        letterSpacing: Binding<Double>,
        wordSpacing: Binding<Double>,
        marginScale: Binding<Double>,
        justify: Binding<Bool>,
        customLayoutEnabled: Binding<Bool>,
        leafPreviewText: String,
        canReset: Bool,
        previewBackground: Color,
        previewForeground: Color,
        themeFontFamily: String? = nil,
        themeFontDisplayName: String = "System",
        availableFonts: [String] = ReaderThemeCustomizationSheet.bundledFonts,
        onCommit: @escaping () -> Void,
        onDiscard: @escaping () -> Void,
        onReset: @escaping () -> Void
    ) {
        self._fontFamily = fontFamily
        self._bold = bold
        self._lineSpacing = lineSpacing
        self._letterSpacing = letterSpacing
        self._wordSpacing = wordSpacing
        self._marginScale = marginScale
        self._justify = justify
        self._customLayoutEnabled = customLayoutEnabled
        self.leafPreviewText = leafPreviewText
        self.canReset = canReset
        self.previewBackground = previewBackground
        self.previewForeground = previewForeground
        self.themeFontFamily = themeFontFamily
        self.themeFontDisplayName = themeFontDisplayName
        self.availableFonts = availableFonts
        self.onCommit = onCommit
        self.onDiscard = onDiscard
        self.onReset = onReset
    }

    /// Le sélecteur se déplie DANS la carte, comme Books : pas d'écran
    /// poussé ni de sheet. Le chevron pivote de « › » à « ⌄ ».
    @State private var fontPickerExpanded = false

    public var body: some View {
        // Apple Books pattern : the preview surface and the header
        // sit on the THEME's background colour, extending edge-to-
        // edge from the top of the sheet down to the first section.
        // The rest of the sheet (Texte / Accessibilité / Reset) uses
        // a separate, neutral background. We achieve this by giving
        // the preview area a `.background(previewBackground)` that
        // ignores horizontal safe area, then a divider into the
        // sections area which sits on `systemBackground`.
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                preview
                    .padding(.bottom, 18)
            }
            .background(previewBackground.ignoresSafeArea(edges: .top))
            ScrollView {
                VStack(spacing: 24) {
                    textSection
                    accessibilitySection
                    justifyRow
                    resetButton
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            // Fond GROUPÉ, pas `.systemBackground`. Mesuré sur Books :
            // #F3F2F7 en clair et #1C1C1D en sombre — soit exactement
            // `systemGroupedBackground` dans sa résolution « elevated »,
            // celle qu'iOS applique aux présentations modales. Les cartes
            // sont alors blanches PAR-DESSUS ce gris. Nous avions les deux
            // à l'envers (page blanche, cartes grises), donc les cartes ne
            // se détachaient pas du fond.
            .background(Color(.systemGroupedBackground))
        }
        .background(Color(.systemGroupedBackground))
    }

    // ── Header ────────────────────────────────────────────────────────────

    private var header: some View {
        // Apple Books button styling :
        //   X (discard) → SUBTLE circle (foreground tinted at ~12 %)
        //                  with the foreground colour as the icon.
        //   ✓ (commit)  → cercle plein CONTRASTÉ qui suit l'APPARENCE,
        //                  pas le thème : noir à glyphe blanc en clair,
        //                  blanc à glyphe noir en sombre (mesuré sur
        //                  Books : #0D0A03 / #FFFFFB — cf. §12.4 de
        //                  BOOKS-READER-SETTINGS-RE.md). Ce commentaire
        //                  affirmait avant que le cercle prenait la
        //                  couleur d'avant-plan du thème ; c'est faux —
        //                  celle de Calme vaut #32281E, un brun.
        ZStack {
            Text("Customize Theme")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(previewForeground)
            HStack {
                Button {
                    Haptic.tap()
                    onDiscard()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                        // Le cercle est plus CLAIR que le fond du thème
                        // (#EFE3CC → #F8EDD8 en clair, #403B31 → #5A5346 en
                        // sombre) : c'est un matériau translucide, pas
                        // l'avant-plan à 12 % — celui-ci assombrissait, donc
                        // allait dans le mauvais sens. Un matériau s'adapte
                        // en plus à chaque thème, ce qu'une couleur figée ne
                        // ferait pas.
                        .foregroundStyle(readerIsDark ? Color.white : Color.black)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                Spacer()
                Button {
                    Haptic.tap()
                    onCommit()
                } label: {
                    // Noir plein sur apparence claire, blanc plein sur
                    // sombre — mesuré sur Books : #0D0A03 et #FFFFFB. Ce
                    // n'est PAS l'avant-plan du thème, qui vaut #32281E
                    // (un brun) pour Calme. Le bouton suit l'apparence.
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(readerIsDark ? Color.black : Color.white)
                        .background(Circle().fill(readerIsDark ? Color.white : Color.black))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Confirm")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 8)
    }

    // ── Live preview ──────────────────────────────────────────────────────

    /// Sample paragraph rendered live with every current setting
    /// applied. iOS Books uses a `BEThemePreviewWKWebView` (WKWebView
    /// inheriting the book's CSS body) — we render the same effect
    /// via SwiftUI Text + AttributedString, mapping each setting to
    /// its visual equivalent : font-family → AttributedString.font ;
    /// font-weight → font descriptor weight ; line-height →
    /// `.lineSpacing(_:)` ; letter-spacing → `.kern` ; word-spacing →
    /// `.tracking` ; text-align: justify → `.multilineTextAlignment` ;
    /// background + colour → theme's bg/fg passed in via init.
    private var preview: some View {
        let baseSize: CGFloat = 17
        let weight: UIFont.Weight = bold ? .bold : .regular
        // Resolve the active font family : the picker's "System"
        // sentinel means "inherit from theme", so we fall back to the
        // `themeFontFamily` argument before defaulting to system SF.
        let effectiveFamily: String? = {
            if fontFamily == "System" || fontFamily.isEmpty {
                return themeFontFamily
            }
            return fontFamily
        }()
        // Walk the same PostScript-name fallback chains the active
        // theme uses (Publico → PublicoText-Roman, Canela →
        // CanelaText-Regular, Proxima Nova → AvenirNext-Regular …)
        // — `UIFont(name:)` requires a PostScript name, not a
        // family name, so passing "Canela" or "Publico" returns nil
        // and the preview falls back to SF. Resolve through the
        // candidate chain first.
        func resolved(at size: CGFloat) -> UIFont {
            let candidates: [String]
            switch effectiveFamily {
            case "Publico", "Publico Text":
                candidates = ["PublicoText-Roman", "Publico Text", "PublicoText",
                              "Publico", "Publico-Text",
                              "HoeflerText-Regular", "Hoefler Text"]
            case "Canela", "Canela Text":
                candidates = ["CanelaText-Regular", "Canela Text", "CanelaText",
                              "Canela-Regular", "Canela",
                              "Palatino-Roman", "Palatino"]
            case "Proxima Nova":
                candidates = ["ProximaNova-Regular", "Proxima Nova", "ProximaNova",
                              "AvenirNext-Regular", "Avenir Next"]
            default:
                candidates = effectiveFamily.map { [$0] } ?? []
            }
            for name in candidates {
                if let f = UIFont(name: name, size: size) { return f }
            }
            // Generic family-name → first PostScript face fallback —
            // handles every iOS-bundled family (Avenir, Bodoni 72,
            // Iowan Old Style, …) the picker exposes.
            if let family = effectiveFamily,
               let postscriptName = UIFont.fontNames(forFamilyName: family).first,
               let f = UIFont(name: postscriptName, size: size) {
                return f
            }
            return UIFont.systemFont(ofSize: size, weight: weight)
        }
        let baseResolved = resolved(at: baseSize)
        let font: UIFont = {
            let traits: [UIFontDescriptor.TraitKey: Any] = [.weight: weight.rawValue]
            let descriptor = baseResolved.fontDescriptor.addingAttributes([.traits: traits])
            return UIFont(descriptor: descriptor, size: baseSize)
        }()
        let displayFont = resolved(at: baseSize * 2.6)
        let textToShow: String = {
            let trimmed = leafPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? ReaderThemeCustomizationSheet.previewSampleText : trimmed
        }()
        // Build the EXACT same NSAttributedString attributes the
        // leaf's block rows use (paragraph style with justify + line-
        // height multiple, kerning, tracking) and render through a
        // UITextView via PreviewBlockView. This guarantees pixel-
        // for-pixel parity with what the user gets on the actual
        // leaf — no SwiftUI Text approximation.
        let paragraph: NSMutableParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.alignment = justify ? .justified : .natural
            if customLayoutEnabled {
                p.lineHeightMultiple = CGFloat(lineSpacing)
            }
            return p
        }()
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(previewForeground),
            .paragraphStyle: paragraph,
        ]
        if customLayoutEnabled {
            if letterSpacing != 0 {
                attrs[.kern] = CGFloat(letterSpacing * baseSize)
            }
            if wordSpacing != 0 {
                attrs[.tracking] = CGFloat(wordSpacing * baseSize)
            }
        }
        let body = NSAttributedString(string: textToShow, attributes: attrs)
        return VStack(alignment: .leading, spacing: 14) {
            Text("Aa")
                .font(Font(displayFont))
                .foregroundStyle(previewForeground)
            PreviewBlockView(attributed: body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, customLayoutEnabled
                 ? 20 + CGFloat(marginScale * 60) : 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: 200, alignment: .topLeading)
        .clipped()
    }

    // ── "Texte" section ───────────────────────────────────────────────────

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Text")
            VStack(spacing: 0) {
                Button {
                    Haptic.tap()
                    withAnimation(.snappy(duration: 0.25)) { fontPickerExpanded.toggle() }
                } label: {
                    HStack {
                        Text("Aa")
                            .font(.system(size: 22, weight: .regular))
                            .frame(width: 32, alignment: .leading)
                        Text("Font")
                            .font(.body)
                        Spacer()
                        // Show the theme's display name when the user
                        // hasn't picked a custom font ("System" =
                        // inherit), else the custom font's name.
                        Text(fontFamily == "System" ? themeFontDisplayName : fontFamily)
                            .foregroundStyle(.secondary)
                            .font(.body)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(fontPickerExpanded ? 90 : 0))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if fontPickerExpanded { inlineFontList }
                Divider().padding(.leading, 56)
                HStack {
                    Text("B")
                        .font(.system(size: 22, weight: .bold))
                        .frame(width: 32, alignment: .leading)
                    Text("Bold")
                        .font(.body)
                    Spacer()
                    Toggle("", isOn: $bold)
                        .labelsHidden()
                        .tint(.green)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }

    // ── "Accessibilité et options de présentation" section ───────────────

    /// Liste des polices, dépliée à l'intérieur de la carte.
    ///
    /// Books ne pousse pas d'écran et n'ouvre pas de sheet : la liste apparaît
    /// sous la ligne « Police », et **chaque nom est rendu dans sa propre
    /// police** — c'est ce qui permet de choisir en voyant plutôt qu'en
    /// lisant. La police active porte une coche.
    @ViewBuilder
    private var inlineFontList: some View {
        ForEach(availableFonts, id: \.self) { family in
            Divider().padding(.leading, 56)
            Button {
                Haptic.tap()
                fontFamily = family
                withAnimation(.snappy(duration: 0.25)) { fontPickerExpanded = false }
            } label: {
                HStack {
                    Text(family == "System" ? "Original" : family)
                        .font(rowFont(for: family, size: 17))
                    Spacer()
                    if fontFamily == family {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                .padding(.leading, 56)
                .padding(.trailing, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Rend un nom dans sa propre famille, sinon en police système.
    ///
    /// `UIFont(name:)` attend un nom PostScript et échoue sur la plupart des
    /// noms de famille (« Avenir Next », « Canela Text »), d'où le repli par
    /// `fontNames(forFamilyName:)`. Un nom lisible dans la mauvaise fonte
    /// vaut mieux qu'une ligne vide.
    private func rowFont(for family: String, size: CGFloat) -> Font {
        guard family != "System" else { return themeRowFont(size: size) }
        if let f = UIFont(name: family, size: size) { return Font(f) }
        if let ps = UIFont.fontNames(forFamilyName: family).first,
           let f = UIFont(name: ps, size: size) {
            return Font(f)
        }
        return .system(size: size)
    }

    /// Police de la ligne « Original » : celle du thème actif, puisque
    /// « Original » signifie « hérite du thème ». Les familles fournies avec
    /// l'app portent des noms PostScript qui ne dérivent pas du nom affiché,
    /// d'où la table de candidats.
    private func themeRowFont(size: CGFloat) -> Font {
        let candidates: [String] = switch themeFontFamily {
        case "Publico":      ["PublicoText-Roman", "Publico Text", "PublicoText", "Publico"]
        case "Canela":       ["CanelaText-Regular", "Canela Text", "CanelaText", "Canela"]
        case "Proxima Nova": ["ProximaNova-Regular", "Proxima Nova", "AvenirNext-Regular"]
        case let .some(f):   [f]
        case .none:          []
        }
        for name in candidates {
            if let f = UIFont(name: name, size: size) { return Font(f) }
        }
        if let family = themeFontFamily,
           let ps = UIFont.fontNames(forFamilyName: family).first,
           let f = UIFont(name: ps, size: size) {
            return Font(f)
        }
        return .system(size: size)
    }

    /// Vrai quand la surface du lecteur est sombre.
    ///
    /// La sheet ne reçoit que des couleurs déjà résolues, jamais l'apparence :
    /// on la déduit donc de la luminance du fond, ce qui reste juste que la
    /// noirceur vienne du mode système ou de la variante sombre du thème, et
    /// garantit que le bouton ✓ ne devienne jamais invisible sur son fond.
    /// Pondérations Rec. 601, celles utilisées pour le contraste perçu.
    private var readerIsDark: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(previewBackground).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r + 0.587 * g + 0.114 * b) < 0.5
    }

    private var accessibilitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Accessibility & Layout Options")
            VStack(spacing: 0) {
                HStack {
                    Text("Customize")
                        .font(.body)
                    Spacer()
                    Toggle("", isOn: $customLayoutEnabled)
                        .labelsHidden()
                        .tint(.green)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if customLayoutEnabled {
                    Divider().padding(.leading, 16)
                    spacingSlider(
                        labelKey: "LINE SPACING",
                        icon: "arrow.up.and.down.text.horizontal",
                        value: $lineSpacing,
                        range: 0.8...2.4,
                        formatter: multiplierFormatter
                    )
                    Divider().padding(.leading, 56)
                    spacingSlider(
                        labelKey: "CHARACTER SPACING",
                        icon: "textformat.characters.arrow.left.and.right",
                        value: $letterSpacing,
                        range: -0.05...0.20,
                        formatter: percentFormatter
                    )
                    Divider().padding(.leading, 56)
                    spacingSlider(
                        labelKey: "WORD SPACING",
                        icon: "text.word.spacing",
                        value: $wordSpacing,
                        range: -0.10...0.30,
                        formatter: percentFormatter
                    )
                    Divider().padding(.leading, 56)
                    spacingSlider(
                        labelKey: "MARGINS",
                        icon: "rectangle.portrait",
                        value: $marginScale,
                        range: 0.0...0.6,
                        formatter: percentFormatter
                    )
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }

    private func spacingSlider(labelKey: LocalizedStringKey,
                               icon: String,
                               value: Binding<Double>,
                               range: ClosedRange<Double>,
                               formatter: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(labelKey)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(.primary.opacity(0.7))
                    .frame(width: 28)
                Slider(value: value, in: range)
                    .tint(.primary)
                Text(formatter(value.wrappedValue))
                    .font(.system(size: 14, weight: .regular).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 16)
    }

    private var justifyRow: some View {
        HStack {
            Text("Justify Text")
                .font(.body)
            Spacer()
            Toggle("", isOn: $justify)
                .labelsHidden()
                .tint(.green)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var resetButton: some View {
        Button {
            Haptic.tap()
            onReset()
        } label: {
            // Apple Books renders the Reset action in red when there
            // are overrides to revert, greyed out (.secondary) when
            // the leaf is already at the theme's factory defaults.
            Text("Reset Theme")
                .font(.body)
                .foregroundStyle(canReset ? Color.red : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
        }
        .buttonStyle(.plain)
        .disabled(!canReset)
    }

    private func sectionLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.primary)
            .padding(.leading, 4)
    }

    /// Books affiche « 0 % » en français (espace avant le signe) et
    /// « 0% » en anglais. `String(format: "%.0f %%")` imposait l'espace
    /// dans les deux langues ; `.formatted(.percent)` applique la règle
    /// typographique de la locale active.
    private func percentFormatter(_ v: Double) -> String {
        v.formatted(.percent.precision(.fractionLength(0)))
    }

    /// L'interligne s'affiche « 1,55 » en français et « 1.55 » en anglais.
    /// `String(format: "%.2f")` imposait le point décimal partout.
    private func multiplierFormatter(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(2)))
    }

    // ── Constants ─────────────────────────────────────────────────────────

    /// Sample text shown in the live preview. Mimics Apple Books'
    /// `previewText` ivar — a few lines of evocative narrative copy.
    public static let previewSampleText: String = """
On the day I cast out my first demon, I hadn't set out to do that. \
Even when I started praying for the woman involved, I didn't think, \
"A demon needs to be cast out of her." But that is exactly what happened.
"""

    /// Reading-friendly font families exposed in the picker —
    /// every entry is either iOS-bundled or shipped inside the app
    /// (Publico Text, Canela Text via `Resources/Fonts/Bundled/`).
    /// Ordre **alphabétique à plat**, « System » épinglé en tête.
    ///
    /// Books n'ordonne pas par catégorie : l'ordre relevé sur l'appareil est
    /// Original, Athelas, Avenir Next, Canela, Charter, Georgia, Iowan… —
    /// soit un simple tri alphabétique après l'entrée héritée du thème
    /// (§12.5). Cette liste était auparavant groupée en sérif / sans-sérif /
    /// monospace sous un commentaire qui la disait déjà « alphabetised ».
    @MainActor public static let bundledFonts: [String] = [
        "System",
        "Athelas",
        "Avenir",
        "Avenir Next",
        "Avenir Next Condensed",
        "Baskerville",
        "Bodoni 72",
        "Canela Text",                 // fournie avec l'app (.ttc)
        "Charter",
        "Cochin",
        "Courier New",
        "Didot",
        "Futura",
        "Georgia",
        "Gill Sans",
        "Helvetica Neue",
        "Hoefler Text",
        "Iowan Old Style",
        "Menlo",
        "Optima",
        "Palatino",
        "Publico Text",                // fournie avec l'app (.ttc)
        "Times New Roman",
        "Trebuchet MS",
        "Verdana",
    ]
}

// ── Preview text view (real Pinkha-style block rendering) ───────────────────

/// Read-only `UITextView` wrapper that renders the preview prose with
/// the EXACT same `NSAttributedString` attributes the leaf's block
/// rows produce — paragraph style (justify + line-height multiple),
/// kerning, tracking, font, foreground colour. SwiftUI's native
/// `Text` lacks a `.justified` alignment ; this bridge gives the
/// customize sheet a WYSIWYG preview that matches the live leaf
/// rendering pixel-for-pixel.
private struct PreviewBlockView: UIViewRepresentable {
    let attributed: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = false
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainerInset = .zero
        tv.adjustsFontForContentSizeCategory = false
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        // Re-apply on every change so the preview tracks live slider
        // drags / toggle flips.
        tv.attributedText = attributed
    }
}
