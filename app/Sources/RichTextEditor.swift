import SwiftUI
import UIKit

let chaqaqSelectionTint = UIColor(named: "SelectionTint") ?? .systemOrange

// ── Clés d'attributs custom ───────────────────────────────────────────────────

extension NSAttributedString.Key {
    static let chaqaqColor  = NSAttributedString.Key("com.chaqaq.color")
    static let chaqaqBold   = NSAttributedString.Key("com.chaqaq.bold")
    static let chaqaqItalic = NSAttributedString.Key("com.chaqaq.italic")
    static let chaqaqObliqueness = NSAttributedString.Key("NSObliqueness")
}

// ── Utilitaire font (libre pour usage dans spansToAttributed) ─────────────

func fontWithTraits(_ base: UIFont, bold: Bool, italic: Bool) -> UIFont {
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

// Italique avec un poids précis — `.italicSystemFont` est toujours regular.
func italicFontWithWeight(_ size: CGFloat, weight: UIFont.Weight) -> UIFont {
    let base = UIFont.systemFont(ofSize: size, weight: weight)
    if let d = base.fontDescriptor.withSymbolicTraits(.traitItalic) {
        return UIFont(descriptor: d, size: size)
    }
    return .italicSystemFont(ofSize: size)
}

// ── Conversion spans ↔ NSAttributedString ────────────────────────────────────

func spansToAttributed(_ spans: [InlineTextFfi], police: UIFont) -> NSAttributedString {
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
            case .color(let nom):    attrs[.foregroundColor] = uiColorFromName(nom); attrs[.chaqaqColor] = nom
            case .link(let url):     if let u = URL(string: url) { attrs[.link] = u }
            }
        }
        attrs[.font] = fontWithTraits(police, bold: isBold, italic: isItalic)
        if isBold   { attrs[.chaqaqBold]   = true }
        if isItalic {
            attrs[.chaqaqItalic] = true
            attrs[.chaqaqObliqueness] = 0.2
        }
        result.append(NSAttributedString(string: span.content, attributes: attrs))
    }
    return result
}

func attributedToSpans(_ attrStr: NSAttributedString, police: UIFont) -> [InlineTextFfi] {
    guard !attrStr.string.isEmpty else { return [] }
    var spans: [InlineTextFfi] = []
    let traitsBase = police.fontDescriptor.symbolicTraits
    let baseEstBold = traitsBase.contains(.traitBold)
    let baseEstItalic = traitsBase.contains(.traitItalic)
    attrStr.enumerateAttributes(in: NSRange(location: 0, length: attrStr.length)) { attrs, range, _ in
        let text = (attrStr.string as NSString).substring(with: range)
        guard !text.isEmpty else { return }
        var styles: [InlineStyleFfi] = []
        let fontTraits = (attrs[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
        let boldCustom = (attrs[.chaqaqBold] as? Bool) == true
        let italicCustom = (attrs[.chaqaqItalic] as? Bool) == true
        let boldParFonte = fontTraits.contains(.traitBold) && !baseEstBold
        let italicParFonte = fontTraits.contains(.traitItalic) && !baseEstItalic
        let italicParObliqueness = attrs[.chaqaqObliqueness] != nil && !baseEstItalic

        if boldCustom || boldParFonte { styles.append(.bold) }
        if italicCustom || italicParFonte || italicParObliqueness { styles.append(.italic) }
        if (attrs[.underlineStyle]     as? Int) != nil { styles.append(.underline) }
        if (attrs[.strikethroughStyle] as? Int) != nil { styles.append(.strikethrough) }
        if let nom = attrs[.chaqaqColor] as? String    { styles.append(.color(nom)) }
        if let url = attrs[.link]        as? URL       { styles.append(.link(url.absoluteString)) }
        spans.append(InlineTextFfi(content: text, styles: styles))
    }
    return spans
}

/// Convertit un raccourci markdown (à la Notion) en `BlockContentFfi`.
/// Retourne `nil` si la chaîne n'est pas un raccourci reconnu.
/// Pur, testable indépendamment de la couche UI.
func markdownShortcut(for text: String) -> BlockContentFfi? {
    switch text {
    case "# ":          return .heading(level: 1, text: [])
    case "## ":         return .heading(level: 2, text: [])
    case "### ":        return .heading(level: 3, text: [])
    case "> ":          return .quote(icon: "", text: [])
    case "!! ":         return .quote(icon: "💡", text: [])
    case "[ ] ", "[] ": return .todo(done: false, text: [])
    case "---":         return .divider
    default:            return nil
    }
}

func uiColorFromName(_ nom: String) -> UIColor {
    switch nom.lowercased() {
    case "rouge", "red":             return .systemRed
    case "rose", "pink":             return .systemPink
    case "orange":                   return .systemOrange
    case "jaune", "yellow":          return .systemYellow
    case "vert", "green":            return .systemGreen
    case "cyan", "menthe", "mint":   return .cyan
    case "bleu", "blue":             return .systemBlue
    case "violet", "purple":         return .systemPurple
    case "marron", "brown":          return .brown
    case "gris", "gray":             return .systemGray
    default:                         return .label
    }
}

// ── UITextView auto-expansible ────────────────────────────────────────────────

final class ExpandingTextView: UITextView {
    var onShiftEnter: (() -> Void)?
    var onToggleBold: (() -> Void)?
    var onToggleItalic: (() -> Void)?
    var onToggleUnderline: (() -> Void)?
    var onNavigatePrevious: (() -> Void)?
    var onNavigateNext: (() -> Void)?
    var onStopNavigationRepeat: (() -> Void)?

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
                onNavigatePrevious?()
            case .keyboardRightArrow where selectedRange.location == (text as NSString).length && selectedRange.length == 0:
                onNavigateNext?()
            case .keyboardUpArrow where estSurPremiereLigne():
                onNavigatePrevious?()
            case .keyboardDownArrow where estSurDerniereLigne():
                onNavigateNext?()
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
                onStopNavigationRepeat?()
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
    @Environment(\.isEnabled) private var isEnabled
    var placeholder: String = ""
    var baseFont: UIFont = .preferredFont(forTextStyle: .body)
    var extraAttrs: [NSAttributedString.Key: Any]? = nil
    var focusCursorAt: Int? = nil
    var onSave: (() -> Void)?
    var onSaveSpans: (([InlineTextFfi]) -> Void)? = nil
    var onNewBlock: (([InlineTextFfi]) -> Void)?
    var onDeleteBloc: (() -> Void)?
    var onMergeAvecPrecedent: (([InlineTextFfi]) -> Void)?
    var onConvert: ((BlockContentFfi) -> Void)?
    var onLongPressSelection: (() -> Void)? = nil
    var onNavigatePrevious: (() -> Void)? = nil
    var onNavigateNext: (() -> Void)? = nil
    var onStopNavigationRepeat: (() -> Void)? = nil

    func makeUIView(context: Context) -> ExpandingTextView {
        let tv = ExpandingTextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.font = baseFont
        tv.textColor = .label
        tv.tintColor = chaqaqSelectionTint
        tv.isEditable = isEnabled
        tv.isSelectable = isEnabled
        tv.typingAttributes = [.font: baseFont, .foregroundColor: UIColor.label]
        tv.allowsEditingTextAttributes = true
        tv.isScrollEnabled = false
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainerInset = UIEdgeInsets(top: 5, left: 0, bottom: 5, right: 0)
        tv.inputAccessoryView = context.coordinator.makeToolbar()
        context.coordinator.tv = tv
        let coord = context.coordinator
        tv.onShiftEnter = { [weak coord] in
            coord?.shiftEnterTyped = true
            coord?.tv?.insertText("\n")
        }
        tv.onToggleBold      = { [weak coord] in coord?.toggleBold() }
        tv.onToggleItalic    = { [weak coord] in coord?.toggleItalic() }
        tv.onToggleUnderline = { [weak coord] in coord?.toggleUnderline() }
        tv.onNavigatePrevious  = { [weak coord] in coord?.parent.onNavigatePrevious?() }
        tv.onNavigateNext    = { [weak coord] in coord?.parent.onNavigateNext?() }
        tv.onStopNavigationRepeat  = { [weak coord] in coord?.parent.onStopNavigationRepeat?() }
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPressSelection(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.cancelsTouchesInView = false
        longPress.delegate = context.coordinator
        tv.addGestureRecognizer(longPress)
        if spans.isEmpty { tv.attributedText = context.coordinator.placeholder() }
        else { tv.attributedText = withExtras(spansToAttributed(spans, police: baseFont)) }
        return tv
    }

    func updateUIView(_ tv: ExpandingTextView, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        tv.tintColor = chaqaqSelectionTint
        tv.isEditable = isEnabled
        tv.isSelectable = isEnabled
        if !isEnabled && tv.isFirstResponder {
            tv.resignFirstResponder()
            DispatchQueue.main.async { isFocused = false }
        }

        // Ne pas réassigner tv.font pendant l'édition : UITextView.font ré-applique
        // la fonte à TOUT le texte et écraserait le gras/italique par caractère.
        // L'underline (attribut .underlineStyle) survivrait, mais pas .font.
        if !coord.isEditing {
            tv.font = baseFont
            let new = spans.isEmpty
                ? coord.placeholder()
                : withExtras(spansToAttributed(spans, police: baseFont))
            tv.attributedText = new
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

    private func withExtras(_ attr: NSAttributedString) -> NSAttributedString {
        guard let extras = extraAttrs, !extras.isEmpty else { return attr }
        let m = NSMutableAttributedString(attributedString: attr)
        m.addAttributes(extras, range: NSRange(location: 0, length: m.length))
        return m
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // ── Coordinator ───────────────────────────────────────────────────────────

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: RichTextEditor
        weak var tv: ExpandingTextView?
        var isEditing = false
        var isDeleting = false
        var shiftEnterTyped = false
        var lastSelection = NSRange(location: 0, length: 0)
        // Couleur appliquée à la frappe sans sélection : UIKit réinitialise
        // typingAttributes après chaque caractère (et le menu fait perdre le first
        // responder), donc on la ré-applique à chaque insertion. Reste active tant
        // que l'utilisateur ne la désactive pas (re-toggle ou « Aucune »).
        private var pendingColor: String? = nil
        private var toolbarActionInProgress = false
        private var selectionGeneration = 0
        private weak var btnBold: UIButton?
        private weak var btnItalic: UIButton?
        private weak var btnUnderline: UIButton?
        private weak var btnStrike: UIButton?
        private weak var btnColor: UIButton?
        private weak var btnPaste: UIButton?

        init(parent: RichTextEditor) {
            self.parent = parent
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pasteboardChanged),
                name: UIPasteboard.changedNotification,
                object: nil)
        }

        @objc private func pasteboardChanged() {
            DispatchQueue.main.async { [weak self] in self?.updatePasteButton() }
        }

        private func updatePasteButton() {
            setSymbolActive(btnPaste, actif: UIPasteboard.general.hasStrings, nom: "doc.on.clipboard")
        }

        @objc func handleLongPressSelection(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began else { return }
            parent.onLongPressSelection?()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        func placeholder() -> NSAttributedString {
            guard parent.isEnabled else { return NSAttributedString(string: "") }
            return NSAttributedString(string: parent.placeholder,
                                      attributes: [.foregroundColor: UIColor.tertiaryLabel,
                                                   .font: parent.baseFont])
        }

        // ── Delegate ──────────────────────────────────────────────────────────

        func textViewDidBeginEditing(_ tv: UITextView) {
            isEditing = true
            parent.isFocused = true
            rememberSelection(tv.selectedRange, longueur: tv.attributedText.length)
            if tv.textColor == .tertiaryLabel {
                tv.attributedText = NSAttributedString(string: "", attributes: [
                    .font: parent.baseFont,
                    .foregroundColor: UIColor.label
                ])
            }
            tv.typingAttributes = [.font: parent.baseFont, .foregroundColor: UIColor.label]
            updateToolbar()
        }

        func textViewDidChangeSelection(_ tv: UITextView) {
            let selection = normalizedSelection(tv.selectedRange, longueur: tv.attributedText.length)
            if selection.length > 0 {
                rememberSelection(selection, longueur: tv.attributedText.length)
            } else {
                cleanRememberedIfStillEmpty(tv)
            }
            updateToolbar()
        }

        func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // Backspace sur bloc vide → supprimer le bloc
            if text.isEmpty, range == NSRange(location: 0, length: 0), tv.text.isEmpty {
                isDeleting = true
                DispatchQueue.main.async { [weak self] in self?.parent.onDeleteBloc?() }
                return false
            }
            // Backspace au début d'un block non vide → fusionner avec le précédent
            if text.isEmpty, range == NSRange(location: 0, length: 0), !tv.text.isEmpty,
               parent.onMergeAvecPrecedent != nil {
                isDeleting = true
                let spansActuels = attributedToSpans(tv.attributedText, police: parent.baseFont)
                DispatchQueue.main.async { [weak self] in
                    self?.parent.onMergeAvecPrecedent?(spansActuels)
                }
                return false
            }
            // Enter
            if text == "\n" {
                if shiftEnterTyped {
                    // Shift+Enter : laisser le \n s'insérer normalement
                    shiftEnterTyped = false
                    return true
                }
                // Enter normal : couper le bloc et en créer un nouveau.
                // On conserve les attributs (couleur, gras…) de la portion après le curseur.
                let debutApres = range.location + range.length
                let attrAvant = tv.attributedText.attributedSubstring(
                    from: NSRange(location: 0, length: range.location))
                let attrApres = tv.attributedText.attributedSubstring(
                    from: NSRange(location: debutApres, length: tv.attributedText.length - debutApres))
                let afterSpans = attributedToSpans(attrApres, police: parent.baseFont)
                tv.attributedText = attrAvant.string.isEmpty
                    ? NSAttributedString(string: "", attributes: [.font: parent.baseFont, .foregroundColor: UIColor.label])
                    : attrAvant
                tv.selectedRange = NSRange(location: attrAvant.length, length: 0)
                save(attributedToSpans(attrAvant, police: parent.baseFont))
                parent.onNewBlock?(afterSpans)
                return false
            }
            // Couleur de frappe : UIKit réinitialise typingAttributes après chaque
            // caractère, on la ré-injecte juste avant l'insertion.
            if !text.isEmpty, text != "\n", let nom = pendingColor {
                tv.typingAttributes[.foregroundColor] = uiColorFromName(nom)
                tv.typingAttributes[.chaqaqColor]     = nom
            }
            return true
        }

        func textViewDidEndEditing(_ tv: UITextView) {
            isEditing = false
            parent.isFocused = false
            guard !isDeleting else { return }
            save(attributedToSpans(tv.attributedText, police: parent.baseFont))
            if parent.spans.isEmpty { tv.attributedText = placeholder() }
        }

        func textViewDidChange(_ tv: UITextView) {
            let text = tv.text ?? ""

            if let shortcut = markdownShortcut(for: text) {
                parent.onConvert?(shortcut)
                return
            }

            parent.spans = attributedToSpans(tv.attributedText, police: parent.baseFont)
            if tv.selectedRange.length == 0 { clearRememberedSelection() }
            tv.invalidateIntrinsicContentSize()
        }

        // ── Toolbar ───────────────────────────────────────────────────────────

        func makeToolbar() -> UIView {
            let pillH: CGFloat  = 64
            let margeV: CGFloat = 8
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

            func textButton(_ label: String, font: UIFont,
                             souligné: Bool = false, barre: Bool = false, action: Selector) -> UIButton {
                let b = UIButton(type: .custom)
                var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
                if souligné { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if barre    { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                b.setAttributedTitle(NSAttributedString(string: label, attributes: a), for: .normal)
                a[.foregroundColor] = UIColor.label.withAlphaComponent(0.3)
                b.setAttributedTitle(NSAttributedString(string: label, attributes: a), for: .highlighted)
                b.addTarget(self, action: #selector(captureSelectionBeforeToolbar), for: .touchDown)
                b.addTarget(self, action: action, for: .touchUpInside)
                return b
            }

            let iconSize: CGFloat = 22

            func symbolButton(_ nom: String, taille: CGFloat = iconSize, action: Selector) -> UIButton {
                let b   = UIButton(type: .custom)
                let cfg = UIImage.SymbolConfiguration(pointSize: taille, weight: .medium)
                b.setImage(
                    UIImage(systemName: nom, withConfiguration: cfg)?
                        .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal),
                    for: .normal)
                b.addTarget(self, action: #selector(captureSelectionBeforeToolbar), for: .touchDown)
                b.addTarget(self, action: action, for: .touchUpInside)
                return b
            }

            var x: CGFloat = 12
            let btnW: CGFloat = 62

            func ajouter(_ btn: UIButton) {
                btn.frame = CGRect(x: x, y: 0, width: btnW, height: pillH)
                scroll.addSubview(btn)
                x += btnW
            }

            @discardableResult
            func separateur() -> UIView {
                let v = UIView(frame: CGRect(x: x + 4, y: (pillH - 28) / 2, width: 1, height: 28))
                v.backgroundColor = UIColor.separator
                scroll.addSubview(v)
                x += 10
                return v
            }

            let bColler = symbolButton("doc.on.clipboard", action: #selector(paste))
            ajouter(bColler); btnPaste = bColler
            separateur()

            let bG = textButton("B", font: .systemFont(ofSize: 22, weight: .heavy), action: #selector(toggleBold)); ajouter(bG); btnBold = bG
            let bI = symbolButton("italic",        taille: 22, action: #selector(toggleItalic)); ajouter(bI); btnItalic = bI
            let bU = textButton("U", font: .systemFont(ofSize: 22, weight: .medium), souligné: true, action: #selector(toggleUnderline)); ajouter(bU); btnUnderline = bU
            let bS = symbolButton("strikethrough", taille: 22, action: #selector(toggleStrike));    ajouter(bS); btnStrike = bS
            separateur()
            ajouter(symbolButton("return", action: #selector(toolbarLineBreak)))
            separateur()
            let bCouleur = UIButton(type: .custom)
            bCouleur.showsMenuAsPrimaryAction = true
            bCouleur.menu = colorMenu(actuelle: nil)
            bCouleur.addTarget(self, action: #selector(captureSelectionBeforeToolbar), for: .touchDown)
            let cfgH = UIImage.SymbolConfiguration(pointSize: iconSize, weight: .medium)
            bCouleur.setImage(UIImage(systemName: "highlighter", withConfiguration: cfgH)?
                .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal), for: .normal)
            ajouter(bCouleur); btnColor = bCouleur
            separateur()
            ajouter(symbolButton("keyboard.chevron.compact.down", action: #selector(dismissKeyboard)))

            scroll.contentSize = CGSize(width: x + 12, height: pillH)
            return container
        }

        @objc func captureSelectionBeforeToolbar() {
            toolbarActionInProgress = true
            guard let tv else { return }
            if tv.selectedRange.length == 0 { clearRememberedSelection() }
            rememberSelection(tv.selectedRange, longueur: tv.attributedText.length)
        }

        @objc func dismissKeyboard() {
            toolbarActionInProgress = false
            tv?.resignFirstResponder()
        }
        @objc func toolbarLineBreak() {
            toolbarActionInProgress = false
            shiftEnterTyped = true
            tv?.insertText("\n")
        }
        @objc func paste() {
            toolbarActionInProgress = false
            tv?.paste(nil)
        }

        @objc func toggleBold()       { applyStyle(.bold) }
        @objc func toggleItalic()   { applyStyle(.italic) }
        @objc func toggleUnderline()   { applyStyle(.underline) }
        @objc func toggleStrike()      { applyStyle(.strikethrough) }
        private func applyColor(_ nom: String) { applyStyle(.color(nom)) }

        private func clearColor() {
            defer { toolbarActionInProgress = false }
            guard let tv, let attr = tv.attributedText else { return }
            let range = selectionForToolbar(selectionActuelle: tv.selectedRange, longueur: attr.length)
            guard range.length > 0 else {
                var attrs = tv.typingAttributes
                attrs.removeValue(forKey: .chaqaqColor)
                attrs[.foregroundColor] = UIColor.label
                tv.typingAttributes = attrs
                pendingColor = nil
                updateToolbar()
                clearRememberedSelection()
                _ = tv.becomeFirstResponder()
                return
            }
            let m = NSMutableAttributedString(attributedString: attr)
            m.removeAttribute(.chaqaqColor, range: range)
            m.addAttribute(.foregroundColor, value: UIColor.label, range: range)
            tv.textStorage.beginEditing()
            tv.textStorage.setAttributedString(m)
            tv.textStorage.endEditing()
            tv.selectedRange = range
            rememberSelection(range, longueur: m.length)
            save(attributedToSpans(tv.attributedText, police: parent.baseFont))
            updateToolbar()
        }

        private func applyStyle(_ style: InlineStyleFfi) {
            defer { toolbarActionInProgress = false }
            guard let tv, let attr = tv.attributedText else { return }
            let range = selectionForToolbar(selectionActuelle: tv.selectedRange, longueur: attr.length)

            guard range.length > 0 else {
                applyStyleTyping(tv: tv, style: style)
                return
            }

            let m = NSMutableAttributedString(attributedString: attr)

            switch style {
            case .bold:
                let toutBold = touteLaPlage(dans: attr, range: range, verifie: attrsContainBold)
                attr.enumerateAttribute(.font, in: range) { _, r, _ in
                    let italic = attrsContainItalic(attributsA: attr, position: r.location)
                    m.addAttribute(.font, value: fontWithTraits(parent.baseFont, bold: !toutBold, italic: italic), range: r)
                    if italic { m.addAttribute(.chaqaqObliqueness, value: 0.2, range: r) }
                    else       { m.removeAttribute(.chaqaqObliqueness, range: r) }
                }
                if !toutBold { m.addAttribute(.chaqaqBold,    value: true, range: range) }
                else         { m.removeAttribute(.chaqaqBold,              range: range) }

            case .italic:
                let toutItalic = touteLaPlage(dans: attr, range: range, verifie: attrsContainItalic)
                attr.enumerateAttribute(.font, in: range) { _, r, _ in
                    let bold = attrsContainBold(attributsA: attr, position: r.location)
                    m.addAttribute(.font, value: fontWithTraits(parent.baseFont, bold: bold, italic: !toutItalic), range: r)
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
                    m.addAttribute(.foregroundColor, value: uiColorFromName(nom), range: range)
                    m.addAttribute(.chaqaqColor,     value: nom,                     range: range)
                }
            default: break
            }

            tv.textStorage.beginEditing()
            tv.textStorage.setAttributedString(m)
            tv.textStorage.endEditing()
            tv.selectedRange  = range
            rememberSelection(range, longueur: m.length)
            save(attributedToSpans(tv.attributedText, police: parent.baseFont))
            updateToolbar()
            // Le menu couleur (showsMenuAsPrimaryAction) fait perdre le first
            // responder : on le rétablit pour garder le clavier et la sélection.
            _ = tv.becomeFirstResponder()
        }

        private func applyStyleTyping(tv: UITextView, style: InlineStyleFfi) {
            var attrs = tv.typingAttributes
            switch style {
            case .bold:
                let bold   = attrsContainBold(attrs)
                let italic = attrsContainItalic(attrs)
                attrs[.font] = fontWithTraits(parent.baseFont, bold: !bold, italic: italic)
                if !bold { attrs[.chaqaqBold] = true } else { attrs.removeValue(forKey: .chaqaqBold) }
                if italic { attrs[.chaqaqObliqueness] = 0.2 }
                else      { attrs.removeValue(forKey: .chaqaqObliqueness) }
            case .italic:
                let bold   = attrsContainBold(attrs)
                let italic = attrsContainItalic(attrs)
                attrs[.font] = fontWithTraits(parent.baseFont, bold: bold, italic: !italic)
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
                // Source de vérité : pendingColor (typingAttributes est réinitialisé
                // par textViewDidBeginEditing après l'ouverture du menu).
                let currentColor = pendingColor ?? (attrs[.chaqaqColor] as? String)
                if currentColor == nom {
                    attrs.removeValue(forKey: .chaqaqColor)
                    attrs[.foregroundColor] = UIColor.label
                    pendingColor = nil
                } else {
                    attrs[.foregroundColor] = uiColorFromName(nom)
                    attrs[.chaqaqColor]     = nom
                    pendingColor = nom
                }
            default: break
            }
            tv.typingAttributes = attrs
            updateToolbar()
            clearRememberedSelection()
            _ = tv.becomeFirstResponder()
        }

        private func rememberSelection(_ range: NSRange, longueur: Int) {
            let selection = normalizedSelection(range, longueur: longueur)
            guard selection.length > 0 else { return }
            selectionGeneration += 1
            lastSelection = selection
        }

        private func save(_ spans: [InlineTextFfi]) {
            parent.spans = spans
            if let onSaveSpans = parent.onSaveSpans {
                onSaveSpans(spans)
            } else {
                parent.onSave?()
            }
        }

        private func updateToolbar() {
            guard let tv else { return }
            let attr = tv.attributedText ?? NSAttributedString()
            let len  = attr.length
            let range = tv.selectedRange

            let bold: Bool; let italic: Bool; let underline: Bool; let strike: Bool; let couleur: String?
            if range.length > 0, range.location < len {
                let loc = min(range.location, len - 1)
                bold     = touteLaPlage(dans: attr, range: range, verifie: attrsContainBold)
                italic   = touteLaPlage(dans: attr, range: range, verifie: attrsContainItalic)
                underline = attr.attribute(.underlineStyle,     at: loc, effectiveRange: nil) != nil
                strike   = attr.attribute(.strikethroughStyle, at: loc, effectiveRange: nil) != nil
                couleur  = attr.attribute(.chaqaqColor,        at: loc, effectiveRange: nil) as? String
            } else {
                let attrs = tv.typingAttributes
                bold     = attrsContainBold(attrs)
                italic   = attrsContainItalic(attrs)
                underline = attrs[.underlineStyle]     != nil
                strike   = attrs[.strikethroughStyle]  != nil
                // pendingColor prime : typingAttributes est réinitialisé par
                // textViewDidBeginEditing après le menu, mais le mode frappe reste actif.
                couleur  = pendingColor ?? (attrs[.chaqaqColor] as? String)
            }

            setTextActive(btnBold,     actif: bold,      font: .systemFont(ofSize: 22, weight: .heavy))
            setSymbolActive(btnItalic,    actif: italic,    nom: "italic",         taille: 22)
            setTextActive(btnUnderline, actif: underline, font: .systemFont(ofSize: 22, weight: .medium), souligne: true)
            setSymbolActive(btnStrike,       actif: strike,    nom: "strikethrough",  taille: 22)
            updateColorButton(couleur)

            updatePasteButton()
        }

        private func setTextActive(_ btn: UIButton?, actif: Bool, font: UIFont, souligne: Bool = false, barre: Bool = false) {
            guard let btn, let str = btn.attributedTitle(for: .normal)?.string else { return }
            let c: UIColor = actif ? (UIColor(named: "Accent") ?? .tintColor) : .label
            var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: c]
            if souligne { a[.underlineStyle]      = NSUnderlineStyle.single.rawValue }
            if barre    { a[.strikethroughStyle]  = NSUnderlineStyle.single.rawValue }
            btn.setAttributedTitle(NSAttributedString(string: str, attributes: a), for: .normal)
            a[.foregroundColor] = c.withAlphaComponent(0.3)
            btn.setAttributedTitle(NSAttributedString(string: str, attributes: a), for: .highlighted)
        }

        private func setSymbolActive(_ btn: UIButton?, actif: Bool, nom: String, taille: CGFloat = 22) {
            guard let btn else { return }
            let c: UIColor = actif ? (UIColor(named: "Accent") ?? .tintColor) : .secondaryLabel
            let cfg = UIImage.SymbolConfiguration(pointSize: taille, weight: .medium)
            btn.setImage(UIImage(systemName: nom, withConfiguration: cfg)?
                .withTintColor(c, renderingMode: .alwaysOriginal), for: .normal)
        }

        private func colorMenu(actuelle: String?) -> UIMenu {
            let palette: [(String, UIColor, String)] = [
                ("rouge",  .systemRed,    "Rouge"),
                ("rose",   .systemPink,   "Rose"),
                ("orange", .systemOrange, "Orange"),
                ("jaune",  .systemYellow, "Jaune"),
                ("vert",   .systemGreen,  "Vert"),
                ("cyan",   .cyan,         "Cyan"),
                ("bleu",   .systemBlue,   "Bleu"),
                ("violet", .systemPurple, "Violet"),
                ("marron", .brown,        "Marron"),
            ]
            let cfgDot = UIImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            let cfgX   = UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)

            let aucune = UIAction(
                title: "Aucune",
                image: UIImage(systemName: "xmark", withConfiguration: cfgX)
            ) { [weak self] _ in self?.clearColor() }
            if actuelle == nil { aucune.state = .on }

            let items = palette.map { (nom, couleur, label) -> UIAction in
                let img = UIImage(systemName: "circle.fill", withConfiguration: cfgDot)?
                    .withTintColor(couleur, renderingMode: .alwaysOriginal)
                let action = UIAction(title: label, image: img) { [weak self] _ in
                    self?.applyColor(nom)
                }
                if actuelle == nom { action.state = .on }
                return action
            }
            return UIMenu(title: "", children: [aucune] + items)
        }

        private func updateColorButton(_ actuelle: String?) {
            guard let btn = btnColor else { return }
            let iconName = actuelle != nil ? "highlighter.badge.ellipsis" : "highlighter"
            let c: UIColor = actuelle.map { uiColorFromName($0) } ?? .secondaryLabel
            let cfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
            btn.setImage(UIImage(systemName: iconName, withConfiguration: cfg)?
                .withTintColor(c, renderingMode: .alwaysOriginal), for: .normal)
            btn.menu = colorMenu(actuelle: actuelle)
        }

        private func clearRememberedSelection() {
            selectionGeneration += 1
            lastSelection = NSRange(location: 0, length: 0)
        }

        private func cleanRememberedIfStillEmpty(_ textView: UITextView) {
            let generation = selectionGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak textView] in
                guard let self, let textView else { return }
                let selection = self.normalizedSelection(textView.selectedRange, longueur: textView.attributedText.length)
                if self.selectionGeneration == generation && !self.toolbarActionInProgress && selection.length == 0 {
                    self.clearRememberedSelection()
                }
            }
        }

        private func selectionForToolbar(selectionActuelle: NSRange, longueur: Int) -> NSRange {
            let courante = normalizedSelection(selectionActuelle, longueur: longueur)
            if courante.length > 0 { return courante }
            let memorisee = normalizedSelection(lastSelection, longueur: longueur)
            return memorisee.length > 0 ? memorisee : courante
        }

        private func normalizedSelection(_ range: NSRange, longueur: Int) -> NSRange {
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

        private func attrsContainBold(attributsA attr: NSAttributedString, position: Int) -> Bool {
            attrsContainBold(attr.attributes(at: position, effectiveRange: nil))
        }

        private func attrsContainItalic(attributsA attr: NSAttributedString, position: Int) -> Bool {
            attrsContainItalic(attr.attributes(at: position, effectiveRange: nil))
        }

        private func attrsContainBold(_ attrs: [NSAttributedString.Key: Any]) -> Bool {
            if (attrs[.chaqaqBold] as? Bool) == true { return true }
            // Repli sur la fonte : UIKit supprime les attributs custom de typingAttributes
            // après insertion, mais la fonte (grasse) reste fiable. Comparaison au baseFont
            // pour ne pas marquer un title (déjà gras) comme gras appliqué par l'utilisateur.
            guard let f = attrs[.font] as? UIFont else { return false }
            return f.fontDescriptor.symbolicTraits.contains(.traitBold)
                && !parent.baseFont.fontDescriptor.symbolicTraits.contains(.traitBold)
        }

        private func attrsContainItalic(_ attrs: [NSAttributedString.Key: Any]) -> Bool {
            if (attrs[.chaqaqItalic] as? Bool) == true { return true }
            guard let f = attrs[.font] as? UIFont else { return false }
            return f.fontDescriptor.symbolicTraits.contains(.traitItalic)
                && !parent.baseFont.fontDescriptor.symbolicTraits.contains(.traitItalic)
        }
    }
}
