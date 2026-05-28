import SwiftUI
import UIKit

// ── Clés d'attributs custom ───────────────────────────────────────────────────

extension NSAttributedString.Key {
    static let chaqaqColor  = NSAttributedString.Key("com.chaqaq.color")
    static let chaqaqBold   = NSAttributedString.Key("com.chaqaq.bold")
    static let chaqaqItalic = NSAttributedString.Key("com.chaqaq.italic")
}

// ── Utilitaire font (libre pour usage dans spansVersNSAttributed) ─────────────

func fontAvecTraits(_ base: UIFont, bold: Bool, italic: Bool) -> UIFont {
    let size = base.pointSize
    var traits = base.fontDescriptor.symbolicTraits
    if bold   { traits.insert(.traitBold) }   else { traits.remove(.traitBold) }
    if italic { traits.insert(.traitItalic) } else { traits.remove(.traitItalic) }
    if let d = base.fontDescriptor.withSymbolicTraits(traits) {
        return UIFont(descriptor: d, size: size)
    }
    // Fallback : SF Pro ignore withSymbolicTraits dans certains contextes
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

// ── Conversion spans ↔ NSAttributedString ────────────────────────────────────

func spansVersNSAttributed(_ spans: [InlineTextFfi], police: UIFont) -> NSAttributedString {
    guard !spans.isEmpty else { return NSAttributedString() }
    let result = NSMutableAttributedString()
    for span in spans {
        var isBold   = false
        var isItalic = false
        var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.label]
        for style in span.styles {
            switch style {
            case .bold:              isBold = true
            case .italic:            isItalic = true
            case .underline:         attrs[.underlineStyle]      = NSUnderlineStyle.single.rawValue
            case .strikethrough:     attrs[.strikethroughStyle]  = NSUnderlineStyle.single.rawValue
            case .color(let nom):    attrs[.foregroundColor] = uiCouleurDepuisNom(nom); attrs[.chaqaqColor] = nom
            case .link(let url):     if let u = URL(string: url) { attrs[.link] = u }
            }
        }
        attrs[.font] = fontAvecTraits(police, bold: isBold, italic: isItalic)
        if isBold   { attrs[.chaqaqBold]   = true }
        if isItalic { attrs[.chaqaqItalic] = true }
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
        // Attributs custom fiables (priorité sur les traits de police)
        if (attrs[.chaqaqBold]   as? Bool) == true { styles.append(.bold) }
        else if let f = attrs[.font] as? UIFont, f.fontDescriptor.symbolicTraits.contains(.traitBold) { styles.append(.bold) }
        if (attrs[.chaqaqItalic] as? Bool) == true { styles.append(.italic) }
        else if let f = attrs[.font] as? UIFont, f.fontDescriptor.symbolicTraits.contains(.traitItalic) { styles.append(.italic) }
        if (attrs[.underlineStyle]     as? Int) != nil { styles.append(.underline) }
        if (attrs[.strikethroughStyle] as? Int) != nil { styles.append(.strikethrough) }
        if let nom = attrs[.chaqaqColor] as? String    { styles.append(.color(nom)) }
        if let url = attrs[.link]        as? URL       { styles.append(.link(url.absoluteString)) }
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
    var onShiftEnter: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        let cmd = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(gererShiftEnter))
        if #available(iOS 15, *) { cmd.wantsPriorityOverSystemBehavior = true }
        return [cmd]
    }

    @objc private func gererShiftEnter() { onShiftEnter?() }

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
    var extraAttrs: [NSAttributedString.Key: Any]? = nil
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
        let coord = context.coordinator
        tv.onShiftEnter = { [weak coord] in
            coord?.saisieSautDeLigne = true
            coord?.tv?.insertText("\n")
        }
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
            DispatchQueue.main.async {
                _ = tv.becomeFirstResponder()
                let fin = tv.text.count
                tv.selectedRange = NSRange(location: fin, length: 0)
            }
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
        var saisieSautDeLigne = false

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

            if texte.contains("\n") {
                if saisieSautDeLigne {
                    // Shift+Enter : saut de ligne dans le même bloc
                    saisieSautDeLigne = false
                    parent.spans = nsAttributedVersSpans(tv.attributedText, police: parent.baseFont)
                    tv.invalidateIntrinsicContentSize()
                    return
                }
                // Enter normal : nouveau bloc
                let idx   = texte.firstIndex(of: "\n")!
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

            switch texte {
            case "# ":          parent.onConvert?(.heading(level: 1, text: [])); return
            case "## ":         parent.onConvert?(.heading(level: 2, text: [])); return
            case "### ":        parent.onConvert?(.heading(level: 3, text: [])); return
            case "> ":          parent.onConvert?(.quote(icon: "", text: []));   return
            case "[ ] ", "[] ": parent.onConvert?(.todo(done: false, text: [])); return
            case "---":         parent.onConvert?(.divider);                     return
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

            let container = UIView(frame: CGRect(x: 0, y: 0, width: largeur, height: totalH))
            container.backgroundColor = .clear
            container.autoresizingMask = [.flexibleWidth]

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

            let scroll = UIScrollView(frame: pill.bounds)
            scroll.autoresizingMask       = [.flexibleWidth, .flexibleHeight]
            scroll.showsHorizontalScrollIndicator = false
            pill.addSubview(scroll)

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

            guard range.length > 0 else {
                appliquerStyleTyping(tv: tv, style: style)
                return
            }

            let m = NSMutableAttributedString(attributedString: attr)

            switch style {
            case .bold:
                let toutBold = toutCustomAttr(.chaqaqBold, dans: attr, range: range)
                m.enumerateAttribute(.font, in: range) { val, r, _ in
                    let f      = (val as? UIFont) ?? parent.baseFont
                    let italic = (attr.attribute(.chaqaqItalic, at: r.location, effectiveRange: nil) as? Bool) == true
                    m.addAttribute(.font, value: fontAvecTraits(f, bold: !toutBold, italic: italic), range: r)
                }
                if !toutBold { m.addAttribute(.chaqaqBold,    value: true, range: range) }
                else         { m.removeAttribute(.chaqaqBold,              range: range) }

            case .italic:
                let toutItalic = toutCustomAttr(.chaqaqItalic, dans: attr, range: range)
                m.enumerateAttribute(.font, in: range) { val, r, _ in
                    let f    = (val as? UIFont) ?? parent.baseFont
                    let bold = (attr.attribute(.chaqaqBold, at: r.location, effectiveRange: nil) as? Bool) == true
                    m.addAttribute(.font, value: fontAvecTraits(f, bold: bold, italic: !toutItalic), range: r)
                }
                if !toutItalic { m.addAttribute(.chaqaqItalic,    value: true, range: range) }
                else           { m.removeAttribute(.chaqaqItalic,              range: range) }

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

        private func appliquerStyleTyping(tv: UITextView, style: InlineStyleFfi) {
            var attrs = tv.typingAttributes
            switch style {
            case .bold:
                let f      = (attrs[.font] as? UIFont) ?? parent.baseFont
                let bold   = (attrs[.chaqaqBold]   as? Bool) == true
                let italic = (attrs[.chaqaqItalic] as? Bool) == true
                attrs[.font] = fontAvecTraits(f, bold: !bold, italic: italic)
                if !bold { attrs[.chaqaqBold] = true } else { attrs.removeValue(forKey: .chaqaqBold) }
            case .italic:
                let f      = (attrs[.font] as? UIFont) ?? parent.baseFont
                let bold   = (attrs[.chaqaqBold]   as? Bool) == true
                let italic = (attrs[.chaqaqItalic] as? Bool) == true
                attrs[.font] = fontAvecTraits(f, bold: bold, italic: !italic)
                if !italic { attrs[.chaqaqItalic] = true } else { attrs.removeValue(forKey: .chaqaqItalic) }
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

        private func toutCustomAttr(_ key: NSAttributedString.Key,
                                     dans attr: NSAttributedString, range: NSRange) -> Bool {
            var result = true
            attr.enumerateAttribute(key, in: range) { val, _, _ in
                if (val as? Bool) != true { result = false }
            }
            return result
        }
    }
}
