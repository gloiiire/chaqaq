import SwiftUI
import UIKit

// ── Clé d'attribut custom pour le nom de couleur ──────────────────────────────

extension NSAttributedString.Key {
    static let chaqaqColor = NSAttributedString.Key("com.chaqaq.color")
}

// ── Conversion spans ↔ NSAttributedString ────────────────────────────────────

func spansVersNSAttributed(_ spans: [InlineTextFfi], police: UIFont) -> NSAttributedString {
    guard !spans.isEmpty else { return NSAttributedString() }
    let result = NSMutableAttributedString()
    for span in spans {
        var font = police
        var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.label]
        for style in span.styles {
            switch style {
            case .bold:
                var t = font.fontDescriptor.symbolicTraits; t.insert(.traitBold)
                if let d = font.fontDescriptor.withSymbolicTraits(t) { font = UIFont(descriptor: d, size: 0) }
            case .italic:
                var t = font.fontDescriptor.symbolicTraits; t.insert(.traitItalic)
                if let d = font.fontDescriptor.withSymbolicTraits(t) { font = UIFont(descriptor: d, size: 0) }
            case .underline:
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            case .strikethrough:
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case .color(let nom):
                attrs[.foregroundColor] = uiCouleurDepuisNom(nom)
                attrs[.chaqaqColor]     = nom
            case .link(let url):
                if let u = URL(string: url) { attrs[.link] = u }
            }
        }
        attrs[.font] = font
        result.append(NSAttributedString(string: span.content, attributes: attrs))
    }
    return result
}

func nsAttributedVersSpans(_ attrStr: NSAttributedString, police: UIFont) -> [InlineTextFfi] {
    guard !attrStr.string.isEmpty else { return [] }
    var spans: [InlineTextFfi] = []
    attrStr.enumerateAttributes(in: NSRange(location: 0, length: attrStr.length)) { attrs, range, _ in
        let texte = (attrStr.string as NSString).substring(with: range)
        guard !texte.isEmpty else { return }
        var styles: [InlineStyleFfi] = []
        if let f = attrs[.font] as? UIFont {
            if f.fontDescriptor.symbolicTraits.contains(.traitBold)   { styles.append(.bold) }
            if f.fontDescriptor.symbolicTraits.contains(.traitItalic) { styles.append(.italic) }
        }
        if (attrs[.underlineStyle] as? Int) != nil          { styles.append(.underline) }
        if (attrs[.strikethroughStyle] as? Int) != nil      { styles.append(.strikethrough) }
        if let nom = attrs[.chaqaqColor] as? String         { styles.append(.color(nom)) }
        if let url = attrs[.link] as? URL                   { styles.append(.link(url.absoluteString)) }
        spans.append(InlineTextFfi(content: texte, styles: styles))
    }
    return spans
}

func uiCouleurDepuisNom(_ nom: String) -> UIColor {
    switch nom.lowercased() {
    case "rouge", "red":     return .systemRed
    case "bleu", "blue":     return .systemBlue
    case "vert", "green":    return .systemGreen
    case "orange":           return .systemOrange
    case "violet", "purple": return .systemPurple
    case "gris", "gray":     return .systemGray
    default:                 return .label
    }
}

// ── UITextView auto-expansible ────────────────────────────────────────────────

final class ExpandingTextView: UITextView {
    override var intrinsicContentSize: CGSize {
        let w = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        let h = sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height
        return CGSize(width: UIView.noIntrinsicMetric, height: max(h, font?.lineHeight ?? 20))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        invalidateIntrinsicContentSize()
    }
}

// ── RichTextEditor ────────────────────────────────────────────────────────────

struct RichTextEditor: UIViewRepresentable {
    @Binding var spans: [InlineTextFfi]
    @Binding var isFocused: Bool
    var placeholder: String = ""
    var baseFont: UIFont = .preferredFont(forTextStyle: .body)
    var extraAttrs: [NSAttributedString.Key: Any]? = nil  // ex: strikethrough quand done
    var onSave: (() -> Void)?
    var onNewBlock: ((String) -> Void)?
    var onSupprimerBloc: (() -> Void)?
    var onConvert: ((BlockContentFfi) -> Void)?

    func makeUIView(context: Context) -> ExpandingTextView {
        let tv = ExpandingTextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.font = baseFont
        tv.textColor = .label
        tv.typingAttributes = [.font: baseFont, .foregroundColor: UIColor.label]
        tv.isScrollEnabled = false
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainerInset = UIEdgeInsets(top: 5, left: 0, bottom: 5, right: 0)
        tv.inputAccessoryView = context.coordinator.faireToolbar()
        context.coordinator.tv = tv
        if spans.isEmpty { tv.attributedText = context.coordinator.placeholder() }
        else { tv.attributedText = avecExtras(spansVersNSAttributed(spans, police: baseFont)) }
        return tv
    }

    func updateUIView(_ tv: ExpandingTextView, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        tv.font = baseFont

        if !coord.enEdition {
            let nouveau = spans.isEmpty
                ? coord.placeholder()
                : avecExtras(spansVersNSAttributed(spans, police: baseFont))
            tv.attributedText = nouveau
        }

        if isFocused && !tv.isFirstResponder {
            DispatchQueue.main.async { _ = tv.becomeFirstResponder() }
        } else if !isFocused && tv.isFirstResponder {
            tv.resignFirstResponder()
        }
    }

    private func avecExtras(_ attr: NSAttributedString) -> NSAttributedString {
        guard let extras = extraAttrs, !extras.isEmpty else { return attr }
        let m = NSMutableAttributedString(attributedString: attr)
        m.addAttributes(extras, range: NSRange(location: 0, length: m.length))
        return m
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // ── Coordinator ───────────────────────────────────────────────────────────

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichTextEditor
        weak var tv: ExpandingTextView?
        var enEdition = false
        var enCoursDeSupression = false

        init(parent: RichTextEditor) { self.parent = parent }

        func placeholder() -> NSAttributedString {
            NSAttributedString(string: parent.placeholder,
                               attributes: [.foregroundColor: UIColor.tertiaryLabel,
                                            .font: parent.baseFont])
        }

        // ── Delegate ──────────────────────────────────────────────────────────

        func textViewDidBeginEditing(_ tv: UITextView) {
            enEdition = true
            parent.isFocused = true
            if tv.textColor == .tertiaryLabel {
                tv.attributedText = NSAttributedString(string: "", attributes: [
                    .font: parent.baseFont,
                    .foregroundColor: UIColor.label
                ])
            }
            tv.typingAttributes = [.font: parent.baseFont, .foregroundColor: UIColor.label]
        }

        func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text.isEmpty, range == NSRange(location: 0, length: 0), tv.text.isEmpty {
                enCoursDeSupression = true
                DispatchQueue.main.async { [weak self] in
                    self?.parent.onSupprimerBloc?()
                }
                return false
            }
            return true
        }

        func textViewDidEndEditing(_ tv: UITextView) {
            enEdition = false
            parent.isFocused = false
            guard !enCoursDeSupression else { return }
            parent.spans = nsAttributedVersSpans(tv.attributedText, police: parent.baseFont)
            parent.onSave?()
            if parent.spans.isEmpty { tv.attributedText = placeholder() }
        }

        func textViewDidChange(_ tv: UITextView) {
            let texte = tv.text ?? ""

            // Saut de ligne → nouveau bloc
            if let idx = texte.firstIndex(of: "\n") {
                let nsIdx = texte.distance(from: texte.startIndex, to: idx)
                let attrAvant = tv.attributedText.attributedSubstring(from: NSRange(location: 0, length: nsIdx))
                let apres = String(texte[texte.index(after: idx)...])
                tv.attributedText = attrAvant.string.isEmpty
                    ? NSAttributedString(string: "", attributes: [.font: parent.baseFont])
                    : attrAvant
                parent.spans = nsAttributedVersSpans(attrAvant, police: parent.baseFont)
                parent.onSave?()
                parent.onNewBlock?(apres)
                return
            }

            // Raccourcis markdown
            switch texte {
            case "# ":         parent.onConvert?(.heading(level: 1, text: [])); return
            case "## ":        parent.onConvert?(.heading(level: 2, text: [])); return
            case "### ":       parent.onConvert?(.heading(level: 3, text: [])); return
            case "> ":         parent.onConvert?(.quote(icon: "", text: [])); return
            case "[ ] ", "[] ": parent.onConvert?(.todo(done: false, text: [])); return
            case "---":        parent.onConvert?(.divider); return
            default: break
            }

            parent.spans = nsAttributedVersSpans(tv.attributedText, police: parent.baseFont)
            tv.invalidateIntrinsicContentSize()
        }

        // ── Toolbar ───────────────────────────────────────────────────────────

        func faireToolbar() -> UIView {
            let pillH: CGFloat  = 50
            let margeV: CGFloat = 5
            let margeH: CGFloat = 4
            let largeur = UIScreen.main.bounds.width
            let totalH  = pillH + margeV * 2

            // Conteneur transparent (pleine largeur)
            let container = UIView(frame: CGRect(x: 0, y: 0, width: largeur, height: totalH))
            container.backgroundColor = .clear
            container.autoresizingMask = [.flexibleWidth]

            // Pill avec fond adaptatif (comme Notes)
            let pill = UIView(frame: CGRect(x: margeH, y: margeV,
                                            width: largeur - margeH * 2, height: pillH))
            pill.autoresizingMask = [.flexibleWidth]
            pill.backgroundColor = UIColor { t in
                t.userInterfaceStyle == .dark
                    ? UIColor(white: 0.18, alpha: 1)
                    : UIColor.secondarySystemBackground
            }
            pill.layer.cornerRadius  = pillH / 2
            pill.layer.masksToBounds = true
            container.addSubview(pill)

            // Scroll à l'intérieur du pill
            let scroll = UIScrollView(frame: pill.bounds)
            scroll.autoresizingMask       = [.flexibleWidth, .flexibleHeight]
            scroll.showsHorizontalScrollIndicator = false
            pill.addSubview(scroll)

            // ── Fabrique de boutons ───────────────────────────────────────────

            func boutonTexte(_ label: String, font: UIFont,
                             souligné: Bool = false, action: Selector) -> UIButton {
                let b = UIButton(type: .custom)
                var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
                if souligné { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                b.setAttributedTitle(NSAttributedString(string: label, attributes: a), for: .normal)
                a[.foregroundColor] = UIColor.label.withAlphaComponent(0.3)
                b.setAttributedTitle(NSAttributedString(string: label, attributes: a), for: .highlighted)
                b.addTarget(self, action: action, for: .touchUpInside)
                return b
            }

            func boutonCercle(_ couleur: UIColor, action: Selector) -> UIButton {
                let b   = UIButton(type: .custom)
                let cfg = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
                b.setImage(
                    UIImage(systemName: "circle.fill", withConfiguration: cfg)?
                        .withTintColor(couleur, renderingMode: .alwaysOriginal),
                    for: .normal)
                b.addTarget(self, action: action, for: .touchUpInside)
                return b
            }

            func boutonSF(_ nom: String, action: Selector) -> UIButton {
                let b   = UIButton(type: .custom)
                let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
                b.setImage(
                    UIImage(systemName: nom, withConfiguration: cfg)?
                        .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal),
                    for: .normal)
                b.addTarget(self, action: action, for: .touchUpInside)
                return b
            }

            // ── Disposition ───────────────────────────────────────────────────

            var x: CGFloat = 12
            let btnW: CGFloat = 52

            func ajouter(_ btn: UIButton) {
                btn.frame = CGRect(x: x, y: 0, width: btnW, height: pillH)
                scroll.addSubview(btn)
                x += btnW
            }

            func separateur() {
                let v = UIView(frame: CGRect(x: x + 4, y: (pillH - 22) / 2, width: 1, height: 22))
                v.backgroundColor = UIColor.separator
                scroll.addSubview(v)
                x += 10
            }

            ajouter(boutonTexte("B", font: .boldSystemFont(ofSize: 17),   action: #selector(toggleGras)))
            ajouter(boutonTexte("I", font: .italicSystemFont(ofSize: 17), action: #selector(toggleItalique)))
            ajouter(boutonTexte("U", font: .systemFont(ofSize: 17), souligné: true, action: #selector(toggleSouligne)))
            ajouter(boutonSF("strikethrough", action: #selector(toggleBarré)))
            separateur()
            ajouter(boutonCercle(.systemRed,    action: #selector(colorRouge)))
            ajouter(boutonCercle(.systemBlue,   action: #selector(colorBleu)))
            ajouter(boutonCercle(.systemOrange, action: #selector(colorOrange)))
            ajouter(boutonCercle(.systemPurple, action: #selector(colorViolet)))
            separateur()
            ajouter(boutonSF("keyboard.chevron.compact.down", action: #selector(dispenserClavier)))

            scroll.contentSize = CGSize(width: x + 12, height: pillH)
            return container
        }

        @objc func dispenserClavier() { tv?.resignFirstResponder() }
        @objc func toggleGras()       { appliquerStyle(.bold) }
        @objc func toggleItalique()   { appliquerStyle(.italic) }
        @objc func toggleSouligne()   { appliquerStyle(.underline) }
        @objc func toggleBarré()      { appliquerStyle(.strikethrough) }
        @objc func colorRouge()       { appliquerStyle(.color("rouge")) }
        @objc func colorBleu()        { appliquerStyle(.color("bleu")) }
        @objc func colorOrange()      { appliquerStyle(.color("orange")) }
        @objc func colorViolet()      { appliquerStyle(.color("violet")) }

        private func appliquerStyle(_ style: InlineStyleFfi) {
            guard let tv, let attr = tv.attributedText else { return }
            let range = tv.selectedRange

            // Sans sélection → modifier les attributs de frappe (texte futur)
            guard range.length > 0 else {
                appliquerStyleTyping(tv: tv, style: style)
                return
            }

            let m = NSMutableAttributedString(attributedString: attr)

            switch style {
            case .bold:
                let toutBold = toutTrait(.traitBold, dans: attr, range: range)
                m.enumerateAttribute(.font, in: range) { val, r, _ in
                    let f = (val as? UIFont) ?? parent.baseFont
                    let italic = f.fontDescriptor.symbolicTraits.contains(.traitItalic)
                    m.addAttribute(.font, value: fontAvecTraits(f, bold: !toutBold, italic: italic), range: r)
                }
            case .italic:
                let toutItalic = toutTrait(.traitItalic, dans: attr, range: range)
                m.enumerateAttribute(.font, in: range) { val, r, _ in
                    let f = (val as? UIFont) ?? parent.baseFont
                    let bold = f.fontDescriptor.symbolicTraits.contains(.traitBold)
                    m.addAttribute(.font, value: fontAvecTraits(f, bold: bold, italic: !toutItalic), range: r)
                }
            case .underline:
                let deja = attr.attribute(.underlineStyle, at: range.location, effectiveRange: nil) != nil
                if deja { m.removeAttribute(.underlineStyle, range: range) }
                else    { m.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
            case .color(let nom):
                let actuelle = attr.attribute(.chaqaqColor, at: range.location, effectiveRange: nil) as? String
                if actuelle == nom {
                    m.removeAttribute(.foregroundColor, range: range)
                    m.removeAttribute(.chaqaqColor,     range: range)
                    m.addAttribute(.foregroundColor, value: UIColor.label, range: range)
                } else {
                    m.addAttribute(.foregroundColor, value: uiCouleurDepuisNom(nom), range: range)
                    m.addAttribute(.chaqaqColor,     value: nom,                     range: range)
                }
            default: break
            }

            tv.attributedText = m
            tv.selectedRange  = range
            parent.spans = nsAttributedVersSpans(m, police: parent.baseFont)
        }

        // Applique le style aux typingAttributes quand rien n'est sélectionné
        private func appliquerStyleTyping(tv: UITextView, style: InlineStyleFfi) {
            var attrs = tv.typingAttributes
            switch style {
            case .bold:
                let f      = (attrs[.font] as? UIFont) ?? parent.baseFont
                let bold   = f.fontDescriptor.symbolicTraits.contains(.traitBold)
                let italic = f.fontDescriptor.symbolicTraits.contains(.traitItalic)
                attrs[.font] = fontAvecTraits(f, bold: !bold, italic: italic)
            case .italic:
                let f      = (attrs[.font] as? UIFont) ?? parent.baseFont
                let bold   = f.fontDescriptor.symbolicTraits.contains(.traitBold)
                let italic = f.fontDescriptor.symbolicTraits.contains(.traitItalic)
                attrs[.font] = fontAvecTraits(f, bold: bold, italic: !italic)
            case .underline:
                if attrs[.underlineStyle] != nil { attrs.removeValue(forKey: .underlineStyle) }
                else { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            case .color(let nom):
                if (attrs[.chaqaqColor] as? String) == nom {
                    attrs.removeValue(forKey: .chaqaqColor)
                    attrs[.foregroundColor] = UIColor.label
                } else {
                    attrs[.foregroundColor] = uiCouleurDepuisNom(nom)
                    attrs[.chaqaqColor]     = nom
                }
            default: break
            }
            tv.typingAttributes = attrs
        }

        private func fontAvecTraits(_ base: UIFont, bold: Bool, italic: Bool) -> UIFont {
            let size = base.pointSize
            var traits = base.fontDescriptor.symbolicTraits
            if bold { traits.insert(.traitBold) } else { traits.remove(.traitBold) }
            if italic { traits.insert(.traitItalic) } else { traits.remove(.traitItalic) }

            // Tentative via descriptor (préserve la famille de police)
            if let d = base.fontDescriptor.withSymbolicTraits(traits) {
                return UIFont(descriptor: d, size: size)
            }
            // Fallback direct pour SF Pro qui ignore withSymbolicTraits
            switch (bold, italic) {
            case (true, true):
                let desc = UIFont.boldSystemFont(ofSize: size).fontDescriptor
                if let d = desc.withSymbolicTraits([.traitBold, .traitItalic]) { return UIFont(descriptor: d, size: size) }
                return UIFont.boldSystemFont(ofSize: size)
            case (true, false):  return UIFont.boldSystemFont(ofSize: size)
            case (false, true):  return UIFont.italicSystemFont(ofSize: size)
            case (false, false): return UIFont.systemFont(ofSize: size)
            }
        }

        private func toutTrait(_ trait: UIFontDescriptor.SymbolicTraits,
                                dans attr: NSAttributedString, range: NSRange) -> Bool {
            var result = true
            attr.enumerateAttribute(.font, in: range) { val, _, _ in
                // Pas de font → traiter comme "sans trait" (sinon le toggle s'inverse)
                guard let f = val as? UIFont else { result = false; return }
                if !f.fontDescriptor.symbolicTraits.contains(trait) { result = false }
            }
            return result
        }
    }
}
