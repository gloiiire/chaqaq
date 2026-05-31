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

// ── Bouton de menu avec hooks de présentation/fermeture ─────────────────────

/// `UIButton` enrichi : on intercepte `willEndFor` du `UIContextMenuInteraction`
/// interne (que UIButton installe en `showsMenuAsPrimaryAction = true`) pour
/// savoir quand le menu se ferme — y compris quand l'utilisateur dismisse en
/// tapant en dehors (cas où `textViewDidChangeSelection` ne fire pas).
final class MenuButton: UIButton {
    var onMenuWillEnd: (() -> Void)?

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willEndFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        onMenuWillEnd?()
    }
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
    // Undo/redo branchés sur le UndoManager du VM, exposés dans la pill.
    // `*Provider` = closures live qui lisent l'état courant du VM (et pas
    // un snapshot capturé au body). Appelées par le Coordinator dans
    // updateUIView, textViewDidChange et textViewDidChangeSelection — couvre
    // les cas typing, undo/redo, et changements de sélection.
    var onUndo: (() -> Void)? = nil
    var onRedo: (() -> Void)? = nil
    var canUndoProvider: (() -> Bool)? = nil
    var canRedoProvider: (() -> Bool)? = nil

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
            coord?.shiftEnterTyped = false
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
        coord.updateUndoRedoButtons()
        tv.tintColor = chaqaqSelectionTint
        tv.isEditable = isEnabled
        tv.isSelectable = isEnabled
        if !isEnabled && tv.isFirstResponder {
            tv.resignFirstResponder()
            DispatchQueue.main.async { isFocused = false }
        }

        // Skip toute la recomputation quand les spans n'ont pas bougé : SwiftUI
        // re-render le ForEach entier à chaque keystroke (en général sur 1 seul
        // bloc), inutile de reconstruire NSAttributedString pour les N-1 autres.
        if coord.lastSyncedSpans != spans {
            // Ne pas réassigner tv.font pendant l'édition : UITextView.font ré-applique
            // la fonte à TOUT le texte et écraserait le gras/italique par caractère.
            let editingText: NSAttributedString = spans.isEmpty
                ? NSAttributedString(string: "",
                                      attributes: [.font: baseFont, .foregroundColor: UIColor.label])
                : withExtras(spansToAttributed(spans, police: baseFont))
            if !coord.isEditing {
                tv.font = baseFont
                tv.attributedText = spans.isEmpty ? coord.placeholder() : editingText
            } else if tv.attributedText.string != editingText.string {
                // Cas undo/redo pendant l'édition : la VM change les spans sans
                // passer par la frappe. Curseur en fin du texte restauré.
                let savedTyping = tv.typingAttributes
                tv.attributedText = editingText
                tv.typingAttributes = savedTyping
                tv.selectedRange = NSRange(location: editingText.length, length: 0)
            }
            coord.lastSyncedSpans = spans
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
        private weak var btnTextStyle: UIButton?
        private weak var btnColor: UIButton?
        private weak var btnPaste: UIButton?
        private weak var btnUndo: UIButton?
        private weak var btnRedo: UIButton?
        private var lastCanUndo: Bool?
        private var lastCanRedo: Bool?
        /// Cache des spans déjà sync vers le textView — permet de skip toute la
        /// recomputation de spansToAttributed pendant les re-renders SwiftUI où
        /// ce bloc n'a pas changé (cas typique : un AUTRE bloc reçoit la frappe).
        fileprivate var lastSyncedSpans: [InlineTextFfi]?
        // Pill de la toolbar — on l'anime à alpha 0 quand un menu déroulant
        // s'ouvre (style Notes.app : la toolbar laisse la place au menu).
        private weak var toolbarPill: UIView?
        private var toolbarHidden = false
        // Fenêtre de garde : pendant ~700ms après l'ouverture d'un menu, on ignore
        // les `textViewDidChangeSelection` parasites que UIKit émet quand le menu
        // se présente (sinon la pill clignote ou ne se cache jamais).
        private var menuPresentingUntil: Date?

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
            updateUndoRedoButtons()
            // Si l'utilisateur a dismissé un menu (tap dans le texte → selection
            // change), on restaure la pill au cas où elle est encore cachée. On
            // ignore pendant la fenêtre de garde post-ouverture du menu pour ne
            // pas annuler le hide qu'on vient de demander.
            if let until = menuPresentingUntil, Date() < until { return }
            menuPresentingUntil = nil
            setToolbarHidden(false)
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

            // save() = parent.spans + onSaveSpans → vm.saveBlock → capture du burst
            // anchor pour l'undo. On le déclenche à chaque frappe pour que canUndo
            // devienne true dès le 1er caractère (au lieu d'attendre la fermeture
            // du clavier dans textViewDidEndEditing). SQLite WAL absorbe le write.
            save(attributedToSpans(tv.attributedText, police: parent.baseFont))
            if tv.selectedRange.length == 0 { clearRememberedSelection() }
            tv.invalidateIntrinsicContentSize()
            updateUndoRedoButtons()
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
            toolbarPill = pill

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

            // Bouton unique pour B/I/U/S — menu déroulant comme pour les couleurs.
            // Open : `UIDeferredMenuElement.uncached` cache la pill.
            // Close : `onMenuWillEnd` la restaure (couvre le cas « tap dehors »).
            let bTextStyle = MenuButton(type: .custom)
            bTextStyle.showsMenuAsPrimaryAction = true
            bTextStyle.menu = textStyleMenu(bold: false, italic: false, underline: false, strike: false)
            bTextStyle.onMenuWillEnd = { [weak self] in
                self?.menuPresentingUntil = nil
                self?.setToolbarHidden(false)
            }
            let cfgTS = UIImage.SymbolConfiguration(pointSize: iconSize, weight: .medium)
            bTextStyle.setImage(UIImage(systemName: "bold.italic.underline", withConfiguration: cfgTS)?
                .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal), for: .normal)
            ajouter(bTextStyle); btnTextStyle = bTextStyle

            // Highlighter collé à droite de Aa (pas de séparateur entre les deux).
            let bCouleur = MenuButton(type: .custom)
            bCouleur.showsMenuAsPrimaryAction = true
            bCouleur.menu = colorMenu(actuelle: nil)
            bCouleur.onMenuWillEnd = { [weak self] in
                self?.menuPresentingUntil = nil
                self?.setToolbarHidden(false)
            }
            let cfgH = UIImage.SymbolConfiguration(pointSize: iconSize, weight: .medium)
            bCouleur.setImage(UIImage(systemName: "highlighter", withConfiguration: cfgH)?
                .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal), for: .normal)
            ajouter(bCouleur); btnColor = bCouleur

            separateur()
            let bUndo = symbolButton("arrow.uturn.backward", action: #selector(toolbarUndo))
            ajouter(bUndo); btnUndo = bUndo
            let bRedo = symbolButton("arrow.uturn.forward", action: #selector(toolbarRedo))
            ajouter(bRedo); btnRedo = bRedo
            updateUndoRedoButtons()

            separateur()
            ajouter(symbolButton("return", action: #selector(toolbarLineBreak)))
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

        private func setToolbarHidden(_ hidden: Bool) {
            guard hidden != toolbarHidden, let pill = toolbarPill else { return }
            toolbarHidden = hidden
            UIView.animate(withDuration: 0.18, delay: 0,
                           options: [.curveEaseOut, .beginFromCurrentState]) {
                pill.alpha = hidden ? 0 : 1
            }
        }

        @objc func dismissKeyboard() {
            toolbarActionInProgress = false
            tv?.resignFirstResponder()
        }
        @objc func toolbarLineBreak() {
            toolbarActionInProgress = false
            shiftEnterTyped = true
            tv?.insertText("\n")
            // Defensive : `insertText` peut ne pas passer par `shouldChangeTextIn`
            // pour les inserts programmés, le flag ne serait alors pas consommé
            // et la prochaine touche Enter du clavier serait interprétée comme
            // un saut de ligne au lieu de couper le bloc.
            shiftEnterTyped = false
        }
        @objc func paste() {
            toolbarActionInProgress = false
            tv?.paste(nil)
        }
        @objc func toolbarUndo() {
            toolbarActionInProgress = false
            parent.onUndo?()
        }
        @objc func toolbarRedo() {
            toolbarActionInProgress = false
            parent.onRedo?()
        }

        /// Met à jour la couleur et l'opacité des boutons undo/redo selon l'état
        /// live lu via `canUndoProvider`/`canRedoProvider`. Appelé depuis
        /// `updateUIView`, `textViewDidChange` et `textViewDidChangeSelection`
        /// pour couvrir respectivement re-renders SwiftUI, frappe et undo/redo.
        fileprivate func updateUndoRedoButtons() {
            let cU = parent.canUndoProvider?() ?? false
            let cR = parent.canRedoProvider?() ?? false
            // Cache : éviter la création de UIImage à chaque frappe quand l'état
            // n'a pas changé (la closure est appelée à chaque keystroke).
            if cU != lastCanUndo {
                applyEnabled(btnUndo, enabled: cU, symbol: "arrow.uturn.backward")
                lastCanUndo = cU
            }
            if cR != lastCanRedo {
                applyEnabled(btnRedo, enabled: cR, symbol: "arrow.uturn.forward")
                lastCanRedo = cR
            }
        }

        private func applyEnabled(_ btn: UIButton?, enabled: Bool, symbol: String) {
            guard let btn else { return }
            let cfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
            let color: UIColor = enabled ? .secondaryLabel : .tertiaryLabel
            btn.setImage(UIImage(systemName: symbol, withConfiguration: cfg)?
                .withTintColor(color, renderingMode: .alwaysOriginal), for: .normal)
            btn.isEnabled = enabled
            btn.alpha = enabled ? 1.0 : 0.5
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

            updateTextStyleButton(bold: bold, italic: italic, underline: underline, strike: strike)
            updateColorButton(couleur)

            updatePasteButton()
        }


        private func setSymbolActive(_ btn: UIButton?, actif: Bool, nom: String, taille: CGFloat = 22) {
            guard let btn else { return }
            let c: UIColor = actif ? (UIColor(named: "Accent") ?? .tintColor) : .secondaryLabel
            let cfg = UIImage.SymbolConfiguration(pointSize: taille, weight: .medium)
            btn.setImage(UIImage(systemName: nom, withConfiguration: cfg)?
                .withTintColor(c, renderingMode: .alwaysOriginal), for: .normal)
        }

        // Menu déroulant des couleurs. Le contenu est calculé paresseusement via
        // `UIDeferredMenuElement.uncached` : chaque fois que l'utilisateur ouvre
        // le menu, la closure s'exécute — c'est le hook fiable pour cacher la
        // pill au moment précis de la présentation (le `.touchDown` est avalé
        // par le gesture recognizer de `showsMenuAsPrimaryAction`).
        private func colorMenu(actuelle: String?) -> UIMenu {
            let deferred = UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else { completion([]); return }
                self.captureSelectionBeforeToolbar()
                self.menuPresentingUntil = Date().addingTimeInterval(0.7)
                self.setToolbarHidden(true)
                completion(self.colorMenuChildren(actuelle: actuelle))
            }
            return UIMenu(title: "", children: [deferred])
        }

        private func colorMenuChildren(actuelle: String?) -> [UIMenuElement] {
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
            ) { [weak self] _ in
                self?.clearColor()
                self?.menuPresentingUntil = nil
                self?.setToolbarHidden(false)
            }
            if actuelle == nil { aucune.state = .on }

            let items = palette.map { (nom, couleur, label) -> UIAction in
                let img = UIImage(systemName: "circle.fill", withConfiguration: cfgDot)?
                    .withTintColor(couleur, renderingMode: .alwaysOriginal)
                let action = UIAction(title: label, image: img) { [weak self] _ in
                    self?.applyColor(nom)
                    self?.menuPresentingUntil = nil
                    self?.setToolbarHidden(false)
                }
                if actuelle == nom { action.state = .on }
                return action
            }
            return [aucune] + items
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

        // Idem pour B/I/U/S — deferred element pour le hook fiable de présentation.
        private func textStyleMenu(bold: Bool, italic: Bool, underline: Bool, strike: Bool) -> UIMenu {
            let deferred = UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else { completion([]); return }
                self.captureSelectionBeforeToolbar()
                self.menuPresentingUntil = Date().addingTimeInterval(0.7)
                self.setToolbarHidden(true)
                completion(self.textStyleMenuChildren(bold: bold, italic: italic,
                                                      underline: underline, strike: strike))
            }
            return UIMenu(title: "", children: [deferred])
        }

        private func textStyleMenuChildren(bold: Bool, italic: Bool, underline: Bool, strike: Bool) -> [UIMenuElement] {
            let cfg = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            func styleAction(label: String, symbol: String, active: Bool,
                             handler: @escaping () -> Void) -> UIAction {
                let img = UIImage(systemName: symbol, withConfiguration: cfg)
                let action = UIAction(title: label, image: img) { [weak self] _ in
                    handler()
                    self?.menuPresentingUntil = nil
                    self?.setToolbarHidden(false)
                }
                if active { action.state = .on }
                return action
            }
            return [
                styleAction(label: "Gras",     symbol: "bold",          active: bold)      { [weak self] in self?.toggleBold() },
                styleAction(label: "Italique", symbol: "italic",        active: italic)    { [weak self] in self?.toggleItalic() },
                styleAction(label: "Souligné", symbol: "underline",     active: underline) { [weak self] in self?.toggleUnderline() },
                styleAction(label: "Barré",    symbol: "strikethrough", active: strike)    { [weak self] in self?.toggleStrike() },
            ]
        }

        private func updateTextStyleButton(bold: Bool, italic: Bool, underline: Bool, strike: Bool) {
            guard let btn = btnTextStyle else { return }
            let anyActive = bold || italic || underline || strike
            let c: UIColor = anyActive ? (UIColor(named: "Accent") ?? .tintColor) : .secondaryLabel
            let cfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
            btn.setImage(UIImage(systemName: "bold.italic.underline", withConfiguration: cfg)?
                .withTintColor(c, renderingMode: .alwaysOriginal), for: .normal)
            btn.menu = textStyleMenu(bold: bold, italic: italic, underline: underline, strike: strike)
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
