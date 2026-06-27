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

    @State private var showingFontPicker = false

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
            .background(Color(.systemBackground))
        }
        .background(Color(.systemBackground))
        .sheet(isPresented: $showingFontPicker) {
            FontPickerSheet(
                selection: $fontFamily,
                fonts: availableFonts,
                themeFontDisplayName: themeFontDisplayName,
                themeFontFamily: themeFontFamily,
                onClose: { showingFontPicker = false }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // ── Header ────────────────────────────────────────────────────────────

    private var header: some View {
        // Apple Books button styling :
        //   X (discard) → SUBTLE circle (foreground tinted at ~12 %)
        //                  with the foreground colour as the icon.
        //   ✓ (commit)  → INVERTED circle : foreground colour as bg
        //                  + background colour as icon. Stands out as
        //                  the primary action on every theme palette
        //                  (cream → dark circle, dark → light circle).
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
                        .foregroundStyle(previewForeground)
                        .background(Circle().fill(previewForeground.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                Spacer()
                Button {
                    Haptic.tap()
                    onCommit()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(previewBackground)
                        .background(Circle().fill(previewForeground))
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
            sectionLabel("Texte")
            VStack(spacing: 0) {
                Button {
                    Haptic.tap()
                    showingFontPicker = true
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
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
                    .fill(Color(.secondarySystemBackground))
            )
        }
    }

    // ── "Accessibilité et options de présentation" section ───────────────

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
                        formatter: { String(format: "%.2f", $0) }
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
                    .fill(Color(.secondarySystemBackground))
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
                .fill(Color(.secondarySystemBackground))
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
                        .fill(Color(.secondarySystemBackground))
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

    private func percentFormatter(_ v: Double) -> String {
        String(format: "%.0f %%", v * 100)
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
    /// Alphabetised so the picker reads as a font catalogue ; the
    /// "System" entry stays pinned at the top (handled by the picker
    /// rendering, not by sort order).
    @MainActor public static let bundledFonts: [String] = [
        "System",
        // ── Serifs (editorial, body-friendly) ──
        "Athelas",
        "Baskerville",
        "Bodoni 72",
        "Canela Text",                 // bundled (.ttc)
        "Charter",
        "Cochin",
        "Didot",
        "Georgia",
        "Hoefler Text",
        "Iowan Old Style",
        "Palatino",
        "Publico Text",                // bundled (.ttc)
        "Times New Roman",
        // ── Sans-serifs (modern, screen-optimised) ──
        "Avenir",
        "Avenir Next",
        "Avenir Next Condensed",
        "Futura",
        "Gill Sans",
        "Helvetica Neue",
        "Optima",
        "Trebuchet MS",
        "Verdana",
        // ── Monospace ──
        "Menlo",
        "Courier New",
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

// ── Font picker sheet ────────────────────────────────────────────────────────

/// Minimal list-based font picker. Each row renders the family name
/// in its own face so the user can preview the look before picking.
/// The "System" entry is rendered in the active theme's font and
/// suffixed with the theme font's display name in parentheses — that
/// way the user always knows what "System" actually means in the
/// current theme context (Apple Books UX pattern).
struct FontPickerSheet: View {
    @Binding var selection: String
    let fonts: [String]
    let themeFontDisplayName: String
    let themeFontFamily: String?
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List(fonts, id: \.self) { family in
                Button {
                    Haptic.tap()
                    selection = family
                    onClose()
                } label: {
                    HStack {
                        Text(label(for: family))
                            .font(fontFor(family: family))
                            .foregroundStyle(.primary)
                        Spacer()
                        if family == selection {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.primary)
                        }
                    }
                    // Make the full row width (including the gap
                    // between text and checkmark) hit-testable —
                    // without contentShape, only the rendered glyphs
                    // catch the tap.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Font")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { onClose() }
                }
            }
        }
    }

    /// "Theme (Canela Text)" for the System sentinel row — clearer
    /// than the literal "System" which would suggest the device's
    /// system font rather than "use whatever the active theme picks".
    /// Plain family name for every other row.
    private func label(for family: String) -> String {
        family == "System"
            ? "Theme (\(themeFontDisplayName))"
            : family
    }

    /// Resolve a `Font` for the row preview. For "System" we route
    /// through the theme's PostScript-name candidates so the row
    /// renders in the same face the leaf actually uses.
    private func fontFor(family: String) -> Font {
        if family == "System" {
            return systemRowFont
        }
        let resolveSize: CGFloat = 18
        let candidates: [String] = {
            switch family {
            case "Publico Text", "Publico":
                return ["PublicoText-Roman", "Publico Text", "PublicoText",
                        "Publico", "Publico-Text"]
            case "Canela Text", "Canela":
                return ["CanelaText-Regular", "Canela Text", "CanelaText",
                        "Canela-Regular", "Canela"]
            case "Proxima Nova":
                return ["ProximaNova-Regular", "Proxima Nova", "ProximaNova",
                        "AvenirNext-Regular", "Avenir Next"]
            default:
                return [family]
            }
        }()
        for name in candidates {
            if let f = UIFont(name: name, size: resolveSize) { return Font(f) }
        }
        if let ps = UIFont.fontNames(forFamilyName: family).first,
           let f = UIFont(name: ps, size: resolveSize) {
            return Font(f)
        }
        return .system(size: resolveSize)
    }

    private var systemRowFont: Font {
        let resolveSize: CGFloat = 18
        let family = themeFontFamily
        let candidates: [String] = {
            switch family {
            case "Publico":
                return ["PublicoText-Roman", "Publico Text", "PublicoText",
                        "Publico", "Publico-Text"]
            case "Canela":
                return ["CanelaText-Regular", "Canela Text", "CanelaText",
                        "Canela-Regular", "Canela"]
            case "Proxima Nova":
                return ["ProximaNova-Regular", "Proxima Nova", "ProximaNova",
                        "AvenirNext-Regular", "Avenir Next"]
            case let .some(f):
                return [f]
            case .none:
                return []
            }
        }()
        for name in candidates {
            if let f = UIFont(name: name, size: resolveSize) { return Font(f) }
        }
        if let family,
           let ps = UIFont.fontNames(forFamilyName: family).first,
           let f = UIFont(name: ps, size: resolveSize) {
            return Font(f)
        }
        return .system(size: resolveSize)
    }
}
