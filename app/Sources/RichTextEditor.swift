import SwiftUI
import UIKit

// ── Clés d'attributs custom ───────────────────────────────────────────────────

extension NSAttributedString.Key {
    static let chaqaqColor  = NSAttributedString.Key("com.chaqaq.color")
    static let chaqaqBold   = NSAttributedString.Key("com.chaqaq.bold")
    static let chaqaqItalic = NSAttributedString.Key("com.chaqaq.italic")
    static let chaqaqObliqueness = NSAttributedString.Key("NSObliqueness")
}

// ── Utilitaire font (libre pour usage dans spansVersNSAttributed) ─────────────

func fontAvecTraits(_ base: UIFont, bold: Bool, italic: Bool) -> UIFont {
    let size = base.pointSize
    let traitsBase = base.fontDescriptor.symbolicTraits
    let renduBold = bold || traitsBase.contains(.traitBold)
    let renduItalic = italic || traitsBase.contains(.traitItalic)
    switch (renduBold, renduItalic) {
    case (true, true):
        let desc = UIFont.boldSystemFont(ofSize: size).fontDescriptor
        if let d = desc.withSymbolicTraits([.traitBold, .traitItalic]) { return UIFont(descriptor: d, size: size) }
        return UIFont.boldSystemFont(ofSize: size)
    case (true, false):  return UIFont.boldSystemFont(ofSize: size)
    case (false, true):  return UIFont.italicSystemFont(ofSize: size)
    case (false, false): return base
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
        if isItalic {
            attrs[.chaqaqItalic] = true
            attrs[.chaqaqObliqueness] = 0.2
        }
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
        if (attrs[.chaqaqItalic] as? Bool) == true { styles.append(.italic) }
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
    var onToggleBold: (() -> Void)?
    var onToggleItalic: (() -> Void)?
    var onToggleUnderline: (() -> Void)?
    var onNaviguerPrecedent: (() -> Void)?
    var onNaviguerSuivant: (() -> Void)?
    var onNavRepeterArreter: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        let cmd = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(gererShiftEnter))
        if #available(iOS 15, *) { cmd.wantsPriorityOverSystemBehavior = true }
        return [cmd]
    }

    @objc private func gererShiftEnter() { onShiftEnter?() }

    override func toggleBoldface(_ sender: Any?) { onToggleBold?() }
    override func toggleItalics(_ sender: Any?) { onToggleItalic?() }
    override func toggleUnderline(_ sender: Any?) { onToggleUnderline?() }

    override var intrinsicContentSize: CGSize {
        let w = bounds.width > 0 ? bounds.width : (window?.screen.bounds.width ?? 390)
        let h = sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height
        return CGSize(width: UIView.noIntrinsicMetric, height: max(h, font?.lineHeight ?? 20))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        invalidateIntrinsicContentSize()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = gererFleches(presses)
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = gererFleches(presses)
        if !unhandled.isEmpty { super.pressesChanged(unhandled, with: event) }
    }

    @discardableResult
    private func gererFleches(_ presses: Set<UIPress>) -> Set<UIPress> {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { unhandled.insert(press); continue }
            switch key.keyCode {
            case .keyboardLeftArrow where selectedRange.location == 0 && selectedRange.length == 0:
                onNaviguerPrecedent?()
            case .keyboardRightArrow where selectedRange.location == (text as NSString).length && selectedRange.length == 0:
                onNaviguerSuivant?()
            case .keyboardUpArrow where estSurPremiereLigne():
                onNaviguerPrecedent?()
            case .keyboardDownArrow where estSurDerniereLigne():
                onNaviguerSuivant?()
            default:
                unhandled.insert(press)
            }
        }
        return unhandled
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.key?.keyCode {
            case .keyboardLeftArrow, .keyboardRightArrow, .keyboardUpArrow, .keyboardDownArrow:
                onNavRepeterArreter?()
            default: break
            }
        }
        super.pressesEnded(presses, with: event)
    }

    private func estSurPremiereLigne() -> Bool {
        guard !text.isEmpty, let pos = selectedTextRange?.start else { return true }
        let caret = caretRect(for: pos)
        let first = caretRect(for: beginningOfDocument)
        return abs(caret.minY - first.minY) < 2
    }

    private func estSurDerniereLigne() -> Bool {
        guard !text.isEmpty, let pos = selectedTextRange?.start else { return true }
        let caret = caretRect(for: pos)
        let last  = caretRect(for: endOfDocument)
        return abs(caret.minY - last.minY) < 2
    }
}

// ── RichTextEditor ────────────────────────────────────────────────────────────

struct RichTextEditor: UIViewRepresentable {
    @Binding var spans: [InlineTextFfi]
    @Binding var isFocused: Bool
    var placeholder: String = ""
    var baseFont: UIFont = .preferredFont(forTextStyle: .body)
    var extraAttrs: [NSAttributedString.Key: Any]? = nil
    var focusCursorAt: Int? = nil
    var onSave: (() -> Void)?
    var onSaveSpans: (([InlineTextFfi]) -> Void)? = nil
    var onNewBlock: ((String) -> Void)?
    var onSupprimerBloc: (() -> Void)?
    var onFusionnerAvecPrecedent: (([InlineTextFfi]) -> Void)?
    var onConvert: ((BlockContentFfi) -> Void)?
    var onNaviguerPrecedent: (() -> Void)? = nil
    var onNaviguerSuivant: (() -> Void)? = nil
    var onNavRepeterArreter: (() -> Void)? = nil

    func makeUIView(context: Context) -> ExpandingTextView {
        let tv = ExpandingTextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.font = baseFont
        tv.textColor = .label
        tv.typingAttributes = [.font: baseFont, .foregroundColor: UIColor.label]
        tv.allowsEditingTextAttributes = true
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
        tv.onToggleBold      = { [weak coord] in coord?.toggleGras() }
        tv.onToggleItalic    = { [weak coord] in coord?.toggleItalique() }
        tv.onToggleUnderline = { [weak coord] in coord?.toggleSouligne() }
        tv.onNaviguerPrecedent  = { [weak coord] in coord?.parent.onNaviguerPrecedent?() }
        tv.onNaviguerSuivant    = { [weak coord] in coord?.parent.onNaviguerSuivant?() }
        tv.onNavRepeterArreter  = { [weak coord] in coord?.parent.onNavRepeterArreter?() }
        if spans.isEmpty { tv.attributedText = context.coordinator.placeholder() }
        else { tv.attributedText = avecExtras(spansVersNSAttributed(spans, police: baseFont)) }
        return tv
    }

    func updateUIView(_ tv: ExpandingTextView, context: Context) {
        let coord = context.coordinator
        coord.parent = self

        // Ne pas réassigner tv.font pendant l'édition : UITextView.font ré-applique
        // la fonte à TOUT le texte et écraserait le gras/italique par caractère.
        // L'underline (attribut .underlineStyle) survivrait, mais pas .font.
        if !coord.enEdition {
            tv.font = baseFont
            let nouveau = spans.isEmpty
                ? coord.placeholder()
                : avecExtras(spansVersNSAttributed(spans, police: baseFont))
            tv.attributedText = nouveau
        }

        if isFocused && !tv.isFirstResponder {
            let pos = focusCursorAt
            DispatchQueue.main.async {
                _ = tv.becomeFirstResponder()
                let loc = pos.map { min($0, tv.text.count) } ?? tv.text.count
                tv.selectedRange = NSRange(location: loc, length: 0)
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
        var derniereSelection = NSRange(location: 0, length: 0)
        private var actionToolbarEnCours = false
        private var generationSelection = 0
        private weak var btnGras: UIButton?
        private weak var btnItalique: UIButton?
        private weak var btnSouligne: UIButton?
        private weak var btnBarre: UIButton?
        private weak var btnRouge: UIButton?
        private weak var btnBleu: UIButton?
        private weak var btnOrange: UIButton?
        private weak var btnViolet: UIButton?

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
            memoriserSelection(tv.selectedRange, longueur: tv.attributedText.length)
            if tv.textColor == .tertiaryLabel {
                tv.attributedText = NSAttributedString(string: "", attributes: [
                    .font: parent.baseFont,
                    .foregroundColor: UIColor.label
                ])
            }
            tv.typingAttributes = [.font: parent.baseFont, .foregroundColor: UIColor.label]
            mettreAJourToolbar()
        }

        func textViewDidChangeSelection(_ tv: UITextView) {
            let selection = selectionNormalisee(tv.selectedRange, longueur: tv.attributedText.length)
            if selection.length > 0 {
                memoriserSelection(selection, longueur: tv.attributedText.length)
            } else {
                nettoyerSelectionMemoriseeSiToujoursVide(tv)
            }
            mettreAJourToolbar()
        }

        func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // Backspace sur bloc vide → supprimer le bloc
            if text.isEmpty, range == NSRange(location: 0, length: 0), tv.text.isEmpty {
                enCoursDeSupression = true
                DispatchQueue.main.async { [weak self] in self?.parent.onSupprimerBloc?() }
                return false
            }
            // Backspace au début d'un bloc non vide → fusionner avec le précédent
            if text.isEmpty, range == NSRange(location: 0, length: 0), !tv.text.isEmpty,
               parent.onFusionnerAvecPrecedent != nil {
                enCoursDeSupression = true
                let spansActuels = nsAttributedVersSpans(tv.attributedText, police: parent.baseFont)
                DispatchQueue.main.async { [weak self] in
                    self?.parent.onFusionnerAvecPrecedent?(spansActuels)
                }
                return false
            }
            // Enter
            if text == "\n" {
                if saisieSautDeLigne {
                    // Shift+Enter : laisser le \n s'insérer normalement
                    saisieSautDeLigne = false
                    return true
                }
                // Enter normal : couper le bloc et en créer un nouveau
                let attrAvant = tv.attributedText.attributedSubstring(
                    from: NSRange(location: 0, length: range.location))
                let apres = (tv.text as NSString).substring(from: range.location + range.length)
                tv.attributedText = attrAvant.string.isEmpty
                    ? NSAttributedString(string: "", attributes: [.font: parent.baseFont, .foregroundColor: UIColor.label])
                    : attrAvant
                tv.selectedRange = NSRange(location: attrAvant.length, length: 0)
                sauvegarder(nsAttributedVersSpans(attrAvant, police: parent.baseFont))
                parent.onNewBlock?(apres)
                return false
            }
            return true
        }

        func textViewDidEndEditing(_ tv: UITextView) {
            enEdition = false
            parent.isFocused = false
            guard !enCoursDeSupression else { return }
            sauvegarder(nsAttributedVersSpans(tv.attributedText, police: parent.baseFont))
            if parent.spans.isEmpty { tv.attributedText = placeholder() }
        }

        func textViewDidChange(_ tv: UITextView) {
            let texte = tv.text ?? ""

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
            if tv.selectedRange.length == 0 { viderSelectionMemorisee() }
            tv.invalidateIntrinsicContentSize()
        }

        // ── Toolbar ───────────────────────────────────────────────────────────

        func faireToolbar() -> UIView {
            let pillH: CGFloat  = 50
            let margeV: CGFloat = 5
            let margeH: CGFloat = 4
            let largeur = tv?.window?.screen.bounds.width ?? 390
            let totalH  = pillH + margeV * 2

            let container = UIView(frame: CGRect(x: 0, y: 0, width: largeur, height: totalH))
            container.backgroundColor = .clear
            container.autoresizingMask = [.flexibleWidth]

            let pill = UIView(frame: CGRect(x: margeH, y: margeV,
                                            width: largeur - margeH * 2, height: pillH))
            pill.autoresizingMask    = [.flexibleWidth]
            pill.backgroundColor     = .clear
            pill.layer.cornerRadius  = pillH / 2
            pill.layer.masksToBounds = true
            container.addSubview(pill)

            let glass = UIVisualEffectView(effect: UIGlassEffect())
            glass.frame               = pill.bounds
            glass.autoresizingMask    = [.flexibleWidth, .flexibleHeight]
            glass.layer.cornerRadius  = pillH / 2
            glass.clipsToBounds       = true
            pill.addSubview(glass)

            let scroll = UIScrollView(frame: pill.bounds)
            scroll.autoresizingMask       = [.flexibleWidth, .flexibleHeight]
            scroll.showsHorizontalScrollIndicator = false
            scroll.backgroundColor = .clear
            pill.addSubview(scroll)

            func boutonTexte(_ label: String, font: UIFont,
                             souligné: Bool = false, action: Selector) -> UIButton {
                let b = UIButton(type: .custom)
                var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
                if souligné { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                b.setAttributedTitle(NSAttributedString(string: label, attributes: a), for: .normal)
                a[.foregroundColor] = UIColor.label.withAlphaComponent(0.3)
                b.setAttributedTitle(NSAttributedString(string: label, attributes: a), for: .highlighted)
                b.addTarget(self, action: #selector(capturerSelectionAvantToolbar), for: .touchDown)
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
                b.addTarget(self, action: #selector(capturerSelectionAvantToolbar), for: .touchDown)
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
                b.addTarget(self, action: #selector(capturerSelectionAvantToolbar), for: .touchDown)
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

            let bG = boutonTexte("B", font: .boldSystemFont(ofSize: 17),   action: #selector(toggleGras));   ajouter(bG); btnGras     = bG
            let bI = boutonTexte("I", font: .italicSystemFont(ofSize: 17), action: #selector(toggleItalique)); ajouter(bI); btnItalique  = bI
            let bU = boutonTexte("U", font: .systemFont(ofSize: 17), souligné: true, action: #selector(toggleSouligne)); ajouter(bU); btnSouligne = bU
            let bS = boutonSF("strikethrough", action: #selector(toggleBarré)); ajouter(bS); btnBarre = bS
            separateur()
            let bR = boutonCercle(.systemRed,    action: #selector(colorRouge));   ajouter(bR); btnRouge  = bR
            let bB = boutonCercle(.systemBlue,   action: #selector(colorBleu));    ajouter(bB); btnBleu   = bB
            let bO = boutonCercle(.systemOrange, action: #selector(colorOrange));  ajouter(bO); btnOrange = bO
            let bV = boutonCercle(.systemPurple, action: #selector(colorViolet));  ajouter(bV); btnViolet = bV
            separateur()
            ajouter(boutonSF("keyboard.chevron.compact.down", action: #selector(dispenserClavier)))

            scroll.contentSize = CGSize(width: x + 12, height: pillH)
            return container
        }

        @objc func capturerSelectionAvantToolbar() {
            actionToolbarEnCours = true
            guard let tv else { return }
            memoriserSelection(tv.selectedRange, longueur: tv.attributedText.length)
        }

        @objc func dispenserClavier() {
            actionToolbarEnCours = false
            tv?.resignFirstResponder()
        }
        @objc func toggleGras()       { appliquerStyle(.bold) }
        @objc func toggleItalique()   { appliquerStyle(.italic) }
        @objc func toggleSouligne()   { appliquerStyle(.underline) }
        @objc func toggleBarré()      { appliquerStyle(.strikethrough) }
        @objc func colorRouge()       { appliquerStyle(.color("rouge")) }
        @objc func colorBleu()        { appliquerStyle(.color("bleu")) }
        @objc func colorOrange()      { appliquerStyle(.color("orange")) }
        @objc func colorViolet()      { appliquerStyle(.color("violet")) }

        private func appliquerStyle(_ style: InlineStyleFfi) {
            defer { actionToolbarEnCours = false }
            guard let tv, let attr = tv.attributedText else { return }
            let range = selectionPourToolbar(selectionActuelle: tv.selectedRange, longueur: attr.length)

            guard range.length > 0 else {
                appliquerStyleTyping(tv: tv, style: style)
                return
            }

            let m = NSMutableAttributedString(attributedString: attr)

            switch style {
            case .bold:
                let toutBold = touteLaPlage(dans: attr, range: range, verifie: attrsContiennentBold)
                attr.enumerateAttribute(.font, in: range) { _, r, _ in
                    let italic = attrsContiennentItalic(attributsA: attr, position: r.location)
                    m.addAttribute(.font, value: fontAvecTraits(parent.baseFont, bold: !toutBold, italic: italic), range: r)
                    if italic { m.addAttribute(.chaqaqObliqueness, value: 0.2, range: r) }
                    else       { m.removeAttribute(.chaqaqObliqueness, range: r) }
                }
                if !toutBold { m.addAttribute(.chaqaqBold,    value: true, range: range) }
                else         { m.removeAttribute(.chaqaqBold,              range: range) }

            case .italic:
                let toutItalic = touteLaPlage(dans: attr, range: range, verifie: attrsContiennentItalic)
                attr.enumerateAttribute(.font, in: range) { _, r, _ in
                    let bold = attrsContiennentBold(attributsA: attr, position: r.location)
                    m.addAttribute(.font, value: fontAvecTraits(parent.baseFont, bold: bold, italic: !toutItalic), range: r)
                }
                if !toutItalic {
                    m.addAttribute(.chaqaqItalic, value: true, range: range)
                    m.addAttribute(.chaqaqObliqueness, value: 0.2, range: range)
                } else {
                    m.removeAttribute(.chaqaqItalic, range: range)
                    m.removeAttribute(.chaqaqObliqueness, range: range)
                }

            case .underline:
                let deja = attr.attribute(.underlineStyle, at: range.location, effectiveRange: nil) != nil
                if deja { m.removeAttribute(.underlineStyle, range: range) }
                else    { m.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }

            case .strikethrough:
                let deja = attr.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) != nil
                if deja { m.removeAttribute(.strikethroughStyle, range: range) }
                else    { m.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }

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

            tv.textStorage.beginEditing()
            tv.textStorage.setAttributedString(m)
            tv.textStorage.endEditing()
            tv.selectedRange  = range
            memoriserSelection(range, longueur: m.length)
            sauvegarder(nsAttributedVersSpans(tv.attributedText, police: parent.baseFont))
            mettreAJourToolbar()
        }

        private func appliquerStyleTyping(tv: UITextView, style: InlineStyleFfi) {
            var attrs = tv.typingAttributes
            switch style {
            case .bold:
                let bold   = attrsContiennentBold(attrs)
                let italic = attrsContiennentItalic(attrs)
                attrs[.font] = fontAvecTraits(parent.baseFont, bold: !bold, italic: italic)
                if !bold { attrs[.chaqaqBold] = true } else { attrs.removeValue(forKey: .chaqaqBold) }
                if italic { attrs[.chaqaqObliqueness] = 0.2 }
                else      { attrs.removeValue(forKey: .chaqaqObliqueness) }
            case .italic:
                let bold   = attrsContiennentBold(attrs)
                let italic = attrsContiennentItalic(attrs)
                attrs[.font] = fontAvecTraits(parent.baseFont, bold: bold, italic: !italic)
                if !italic {
                    attrs[.chaqaqItalic] = true
                    attrs[.chaqaqObliqueness] = 0.2
                } else {
                    attrs.removeValue(forKey: .chaqaqItalic)
                    attrs.removeValue(forKey: .chaqaqObliqueness)
                }
            case .underline:
                if attrs[.underlineStyle] != nil { attrs.removeValue(forKey: .underlineStyle) }
                else { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            case .strikethrough:
                if attrs[.strikethroughStyle] != nil { attrs.removeValue(forKey: .strikethroughStyle) }
                else { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
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
            mettreAJourToolbar()
            viderSelectionMemorisee()
            _ = tv.becomeFirstResponder()
        }

        private func memoriserSelection(_ range: NSRange, longueur: Int) {
            let selection = selectionNormalisee(range, longueur: longueur)
            guard selection.length > 0 else { return }
            generationSelection += 1
            derniereSelection = selection
        }

        private func sauvegarder(_ spans: [InlineTextFfi]) {
            parent.spans = spans
            if let onSaveSpans = parent.onSaveSpans {
                onSaveSpans(spans)
            } else {
                parent.onSave?()
            }
        }

        private func mettreAJourToolbar() {
            guard let tv else { return }
            let attr = tv.attributedText ?? NSAttributedString()
            let len  = attr.length
            let range = tv.selectedRange

            let bold: Bool; let italic: Bool; let underline: Bool; let strike: Bool; let couleur: String?
            if range.length > 0, range.location < len {
                let loc = min(range.location, len - 1)
                bold     = touteLaPlage(dans: attr, range: range, verifie: attrsContiennentBold)
                italic   = touteLaPlage(dans: attr, range: range, verifie: attrsContiennentItalic)
                underline = attr.attribute(.underlineStyle,     at: loc, effectiveRange: nil) != nil
                strike   = attr.attribute(.strikethroughStyle, at: loc, effectiveRange: nil) != nil
                couleur  = attr.attribute(.chaqaqColor,        at: loc, effectiveRange: nil) as? String
            } else {
                let attrs = tv.typingAttributes
                bold     = attrsContiennentBold(attrs)
                italic   = attrsContiennentItalic(attrs)
                underline = attrs[.underlineStyle]     != nil
                strike   = attrs[.strikethroughStyle]  != nil
                couleur  = attrs[.chaqaqColor] as? String
            }

            setActifTexte(btnGras,     actif: bold,      font: .boldSystemFont(ofSize: 17))
            setActifTexte(btnItalique, actif: italic,    font: .italicSystemFont(ofSize: 17))
            setActifTexte(btnSouligne, actif: underline, font: .systemFont(ofSize: 17), souligne: true)
            setActifSF(btnBarre,       actif: strike,    nom: "strikethrough")
            setActifCouleur(btnRouge,  actif: couleur == "rouge")
            setActifCouleur(btnBleu,   actif: couleur == "bleu")
            setActifCouleur(btnOrange, actif: couleur == "orange")
            setActifCouleur(btnViolet, actif: couleur == "violet")
        }

        private func setActifTexte(_ btn: UIButton?, actif: Bool, font: UIFont, souligne: Bool = false) {
            guard let btn, let str = btn.attributedTitle(for: .normal)?.string else { return }
            let c: UIColor = actif ? .tintColor : .label
            var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: c]
            if souligne { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            btn.setAttributedTitle(NSAttributedString(string: str, attributes: a), for: .normal)
            a[.foregroundColor] = c.withAlphaComponent(0.3)
            btn.setAttributedTitle(NSAttributedString(string: str, attributes: a), for: .highlighted)
        }

        private func setActifSF(_ btn: UIButton?, actif: Bool, nom: String) {
            guard let btn else { return }
            let c: UIColor = actif ? .tintColor : .secondaryLabel
            let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            btn.setImage(UIImage(systemName: nom, withConfiguration: cfg)?
                .withTintColor(c, renderingMode: .alwaysOriginal), for: .normal)
        }

        private func setActifCouleur(_ btn: UIButton?, actif: Bool) {
            btn?.alpha = actif ? 1.0 : 0.45
        }

        private func viderSelectionMemorisee() {
            generationSelection += 1
            derniereSelection = NSRange(location: 0, length: 0)
        }

        private func nettoyerSelectionMemoriseeSiToujoursVide(_ textView: UITextView) {
            let generation = generationSelection
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak textView] in
                guard let self, let textView else { return }
                let selection = self.selectionNormalisee(textView.selectedRange, longueur: textView.attributedText.length)
                if self.generationSelection == generation && !self.actionToolbarEnCours && selection.length == 0 {
                    self.viderSelectionMemorisee()
                }
            }
        }

        private func selectionPourToolbar(selectionActuelle: NSRange, longueur: Int) -> NSRange {
            let courante = selectionNormalisee(selectionActuelle, longueur: longueur)
            if courante.length > 0 { return courante }
            let memorisee = selectionNormalisee(derniereSelection, longueur: longueur)
            return memorisee.length > 0 ? memorisee : courante
        }

        private func selectionNormalisee(_ range: NSRange, longueur: Int) -> NSRange {
            guard range.location != NSNotFound, range.location <= longueur else {
                return NSRange(location: longueur, length: 0)
            }
            let fin = min(range.location + range.length, longueur)
            return NSRange(location: range.location, length: max(0, fin - range.location))
        }

        private func touteLaPlage(
            dans attr: NSAttributedString,
            range: NSRange,
            verifie: ([NSAttributedString.Key: Any]) -> Bool
        ) -> Bool {
            guard range.length > 0 else { return false }
            var result = true
            attr.enumerateAttributes(in: range) { attrs, _, stop in
                if !verifie(attrs) {
                    result = false
                    stop.pointee = true
                }
            }
            return result
        }

        private func attrsContiennentBold(attributsA attr: NSAttributedString, position: Int) -> Bool {
            attrsContiennentBold(attr.attributes(at: position, effectiveRange: nil))
        }

        private func attrsContiennentItalic(attributsA attr: NSAttributedString, position: Int) -> Bool {
            attrsContiennentItalic(attr.attributes(at: position, effectiveRange: nil))
        }

        private func attrsContiennentBold(_ attrs: [NSAttributedString.Key: Any]) -> Bool {
            (attrs[.chaqaqBold] as? Bool) == true
        }

        private func attrsContiennentItalic(_ attrs: [NSAttributedString.Key: Any]) -> Bool {
            (attrs[.chaqaqItalic] as? Bool) == true
        }
    }
}
