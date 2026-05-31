import SwiftUI
import UIKit

/// App-wide selection tint color (falls back to systemOrange if the asset is missing).
let pinkhaSelectionTint = UIColor(named: "SelectionTint") ?? .systemOrange

// ── Custom attribute keys ─────────────────────────────────────────────────────

extension NSAttributedString.Key {
    /// Stores the color name string alongside `.foregroundColor` for a reliable round-trip
    /// between `NSAttributedString` and `[InlineTextFfi]`.
    static let pinkhaColor  = NSAttributedString.Key("com.pinkha.color")
    /// Marks a run as explicitly bold (survives `typingAttributes` resets by UIKit).
    static let pinkhaBold   = NSAttributedString.Key("com.pinkha.bold")
    /// Marks a run as explicitly italic.
    static let pinkhaItalic = NSAttributedString.Key("com.pinkha.italic")
    /// Obliqueness value stored alongside italic to support fonts where `withSymbolicTraits` fails.
    static let pinkhaObliqueness = NSAttributedString.Key("NSObliqueness")
}

// ── Font utility (free function, usable in spansToAttributed) ─────────────────

/// Returns a font derived from `base` with the requested bold/italic traits applied.
/// Falls back to `boldSystemFont`/`italicSystemFont` when `withSymbolicTraits` returns `nil`
/// (SF Pro does not always propagate traits in some iOS contexts).
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

/// Returns an italic font at the given `size` and `weight`.
/// `.italicSystemFont` is always regular weight, so this helper applies the italic trait
/// to a weighted font descriptor when possible.
func italicFontWithWeight(_ size: CGFloat, weight: UIFont.Weight) -> UIFont {
    let base = UIFont.systemFont(ofSize: size, weight: weight)
    if let d = base.fontDescriptor.withSymbolicTraits(.traitItalic) {
        return UIFont(descriptor: d, size: size)
    }
    return .italicSystemFont(ofSize: size)
}

// ── Menu button with presentation/dismissal hooks ────────────────────────────

/// `UIButton` subclass that intercepts `contextMenuInteraction(_:willEndFor:)` on
/// the internal `UIContextMenuInteraction` installed by `showsMenuAsPrimaryAction = true`.
/// This lets us know when the menu closes — including dismissal by tapping outside —
/// a case where `textViewDidChangeSelection` does not fire.
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

// ── Span ↔ NSAttributedString conversion ─────────────────────────────────────

/// Converts an array of `InlineTextFfi` spans to an `NSAttributedString` using `font` as the base.
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
            case .color(let nom):    attrs[.foregroundColor] = uiColorFromName(nom); attrs[.pinkhaColor] = nom
            case .link(let url):     if let u = URL(string: url) { attrs[.link] = u }
            }
        }
        attrs[.font] = fontWithTraits(police, bold: isBold, italic: isItalic)
        if isBold   { attrs[.pinkhaBold]   = true }
        if isItalic {
            attrs[.pinkhaItalic] = true
            attrs[.pinkhaObliqueness] = 0.2
        }
        result.append(NSAttributedString(string: span.content, attributes: attrs))
    }
    return result
}

/// Converts an `NSAttributedString` back to an array of `InlineTextFfi` spans.
/// Detects bold/italic both via custom keys (`.pinkhaBold`/`.pinkhaItalic`) and
/// via the font's symbolic traits (relative to `font` so heading bases are not mistaken for user-applied bold).
func attributedToSpans(_ attrStr: NSAttributedString, police: UIFont) -> [InlineTextFfi] {
    guard !attrStr.string.isEmpty else { return [] }
    var spans: [InlineTextFfi] = []
    let traitsBase = police.fontDescriptor.symbolicTraits
    let baseIsBold = traitsBase.contains(.traitBold)
    let baseIsItalic = traitsBase.contains(.traitItalic)
    attrStr.enumerateAttributes(in: NSRange(location: 0, length: attrStr.length)) { attrs, range, _ in
        let text = (attrStr.string as NSString).substring(with: range)
        guard !text.isEmpty else { return }
        var styles: [InlineStyleFfi] = []
        let fontTraits = (attrs[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
        let boldCustom = (attrs[.pinkhaBold] as? Bool) == true
        let italicCustom = (attrs[.pinkhaItalic] as? Bool) == true
        let boldFromFont = fontTraits.contains(.traitBold) && !baseIsBold
        let italicFromFont = fontTraits.contains(.traitItalic) && !baseIsItalic
        let italicFromObliqueness = attrs[.pinkhaObliqueness] != nil && !baseIsItalic

        if boldCustom || boldFromFont { styles.append(.bold) }
        if italicCustom || italicFromFont || italicFromObliqueness { styles.append(.italic) }
        if (attrs[.underlineStyle]     as? Int) != nil { styles.append(.underline) }
        if (attrs[.strikethroughStyle] as? Int) != nil { styles.append(.strikethrough) }
        if let nom = attrs[.pinkhaColor] as? String    { styles.append(.color(nom)) }
        if let url = attrs[.link]        as? URL       { styles.append(.link(url.absoluteString)) }
        spans.append(InlineTextFfi(content: text, styles: styles))
    }
    return spans
}

/// Converts a Notion-style markdown shortcut string to its `BlockContentFfi` equivalent.
/// Returns `nil` if `text` is not a recognized shortcut.
/// Pure function — independently testable without any UI layer.
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

/// Maps a color name (French or English) to its `UIColor` equivalent.
/// Unknown names fall back to `.label` so text remains readable.
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

// ── Auto-expanding UITextView ─────────────────────────────────────────────────

/// `UITextView` subclass that self-sizes vertically and intercepts hardware-keyboard
/// shortcuts for Shift+Enter, bold/italic/underline toggles, and arrow-key navigation.
final class ExpandingTextView: UITextView {
    var onShiftEnter: (() -> Void)?
    var onToggleBold: (() -> Void)?
    var onToggleItalic: (() -> Void)?
    var onToggleUnderline: (() -> Void)?
    var onNavigatePrevious: (() -> Void)?
    var onNavigateNext: (() -> Void)?
    var onStopNavigationRepeat: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        let cmd = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(handleShiftEnter))
        if #available(iOS 15, *) { cmd.wantsPriorityOverSystemBehavior = true }
        return [cmd]
    }

    @objc private func handleShiftEnter() { onShiftEnter?() }

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
        let unhandled = handleArrows(presses)
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = handleArrows(presses)
        if !unhandled.isEmpty { super.pressesChanged(unhandled, with: event) }
    }

    /// Handles arrow key presses for inter-block navigation. Returns the unhandled presses.
    @discardableResult
    private func handleArrows(_ presses: Set<UIPress>) -> Set<UIPress> {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { unhandled.insert(press); continue }
            switch key.keyCode {
            case .keyboardLeftArrow where selectedRange.location == 0 && selectedRange.length == 0:
                onNavigatePrevious?()
            case .keyboardRightArrow where selectedRange.location == (text as NSString).length && selectedRange.length == 0:
                onNavigateNext?()
            case .keyboardUpArrow where isOnFirstLine():
                onNavigatePrevious?()
            case .keyboardDownArrow where isOnLastLine():
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

    /// Returns `true` if the caret is on the first visual line of the text view.
    private func isOnFirstLine() -> Bool {
        guard !text.isEmpty, let pos = selectedTextRange?.start else { return true }
        let caret = caretRect(for: pos)
        let first = caretRect(for: beginningOfDocument)
        return abs(caret.minY - first.minY) < 2
    }

    /// Returns `true` if the caret is on the last visual line of the text view.
    private func isOnLastLine() -> Bool {
        guard !text.isEmpty, let pos = selectedTextRange?.start else { return true }
        let caret = caretRect(for: pos)
        let last  = caretRect(for: endOfDocument)
        return abs(caret.minY - last.minY) < 2
    }
}

// ── RichTextEditor ────────────────────────────────────────────────────────────

/// `UIViewRepresentable` wrapping `ExpandingTextView` with full rich-text editing:
/// bold/italic/underline/strikethrough/color/link via a glass toolbar pill,
/// markdown shortcuts, Shift+Enter line breaks, and undo/redo integration.
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
    // Undo/redo wired to the VM's UndoManager, exposed in the keyboard pill.
    // `*Provider` = live closures that read the current VM state (not a snapshot
    // captured at body time). Called by the Coordinator in updateUIView,
    // textViewDidChange, and textViewDidChangeSelection — covers typing, undo/redo,
    // and selection changes.
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
        tv.tintColor = pinkhaSelectionTint
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
        tv.tintColor = pinkhaSelectionTint
        tv.isEditable = isEnabled
        tv.isSelectable = isEnabled
        if !isEnabled && tv.isFirstResponder {
            tv.resignFirstResponder()
            DispatchQueue.main.async { isFocused = false }
        }

        // Skip recomputation when spans have not changed: SwiftUI re-renders the
        // entire ForEach on every keystroke (typically for a single block); no need
        // to rebuild NSAttributedString for the N-1 other blocks that did not change.
        if coord.lastSyncedSpans != spans {
            // Do not reassign tv.font while editing: UITextView.font reapplies the
            // font to ALL text and would erase per-character bold/italic.
            let editingText: NSAttributedString = spans.isEmpty
                ? NSAttributedString(string: "",
                                      attributes: [.font: baseFont, .foregroundColor: UIColor.label])
                : withExtras(spansToAttributed(spans, police: baseFont))
            if !coord.isEditing {
                tv.font = baseFont
                tv.attributedText = spans.isEmpty ? coord.placeholder() : editingText
            } else if tv.attributedText.string != editingText.string {
                // Undo/redo while editing: the VM changed spans without going through
                // the keyboard. Restore the cursor to the end of the restored text.
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

    /// Overlays `extraAttrs` (e.g. todo strikethrough) on top of the span-derived attributes.
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
        // Color applied while typing without a selection: UIKit resets typingAttributes
        // after every character (and showing a menu can resign first responder), so we
        // re-inject the color just before each insertion. Stays active until the user
        // toggles it off or chooses "None".
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
        /// Cached spans already synced to the text view — allows skipping the full
        /// `spansToAttributed` recomputation during SwiftUI re-renders where this
        /// block's spans did not change (typical: a different block received the keystroke).
        fileprivate var lastSyncedSpans: [InlineTextFfi]?
        // The toolbar pill — animated to alpha 0 when a dropdown menu opens
        // (Notes.app style: the toolbar steps aside while the menu is visible).
        private weak var toolbarPill: UIView?
        private var toolbarHidden = false
        // Guard window: for ~700 ms after a menu opens, ignore the spurious
        // `textViewDidChangeSelection` events UIKit emits during menu presentation
        // (otherwise the pill flickers or never hides).
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
            setSymbolActive(btnPaste, active: UIPasteboard.general.hasStrings, name: "doc.on.clipboard")
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

        // ── UITextViewDelegate ────────────────────────────────────────────────

        func textViewDidBeginEditing(_ tv: UITextView) {
            isEditing = true
            parent.isFocused = true
            rememberSelection(tv.selectedRange, length: tv.attributedText.length)
            // Clear placeholder when editing begins.
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
            let selection = normalizedSelection(tv.selectedRange, length: tv.attributedText.length)
            if selection.length > 0 {
                rememberSelection(selection, length: tv.attributedText.length)
            } else {
                cleanRememberedIfStillEmpty(tv)
            }
            updateToolbar()
            updateUndoRedoButtons()
            // If the user dismissed a menu (tapped in the text → selection changed),
            // restore the pill in case it is still hidden. Skip during the guard window
            // to avoid cancelling the hide we just requested.
            if let until = menuPresentingUntil, Date() < until { return }
            menuPresentingUntil = nil
            setToolbarHidden(false)
        }

        func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // Backspace on an empty block → delete the block
            if text.isEmpty, range == NSRange(location: 0, length: 0), tv.text.isEmpty {
                isDeleting = true
                DispatchQueue.main.async { [weak self] in self?.parent.onDeleteBloc?() }
                return false
            }
            // Backspace at the beginning of a non-empty block → merge with the previous block
            if text.isEmpty, range == NSRange(location: 0, length: 0), !tv.text.isEmpty,
               parent.onMergeAvecPrecedent != nil {
                isDeleting = true
                let currentSpans = attributedToSpans(tv.attributedText, police: parent.baseFont)
                DispatchQueue.main.async { [weak self] in
                    self?.parent.onMergeAvecPrecedent?(currentSpans)
                }
                return false
            }
            // Enter key
            if text == "\n" {
                if shiftEnterTyped {
                    // Shift+Enter: let the newline insert normally
                    shiftEnterTyped = false
                    return true
                }
                // Regular Enter: split the block and create a new one.
                // Preserve attributes (color, bold…) of the portion after the cursor.
                let afterStart = range.location + range.length
                let attrBefore = tv.attributedText.attributedSubstring(
                    from: NSRange(location: 0, length: range.location))
                let attrAfter = tv.attributedText.attributedSubstring(
                    from: NSRange(location: afterStart, length: tv.attributedText.length - afterStart))
                let afterSpans = attributedToSpans(attrAfter, police: parent.baseFont)
                tv.attributedText = attrBefore.string.isEmpty
                    ? NSAttributedString(string: "", attributes: [.font: parent.baseFont, .foregroundColor: UIColor.label])
                    : attrBefore
                tv.selectedRange = NSRange(location: attrBefore.length, length: 0)
                save(attributedToSpans(attrBefore, police: parent.baseFont))
                parent.onNewBlock?(afterSpans)
                return false
            }
            // Typing color: UIKit resets typingAttributes after each character,
            // so we re-inject the color just before the insertion.
            if !text.isEmpty, text != "\n", let nom = pendingColor {
                tv.typingAttributes[.foregroundColor] = uiColorFromName(nom)
                tv.typingAttributes[.pinkhaColor]     = nom
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

            // save() = update parent.spans + call onSaveSpans → vm.saveBlock → capture the burst
            // anchor for undo. Called on every keystroke so canUndo becomes true from the
            // first character (instead of waiting for the keyboard to close in textViewDidEndEditing).
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

            func symbolButton(_ name: String, size: CGFloat = iconSize, action: Selector) -> UIButton {
                let b   = UIButton(type: .custom)
                let cfg = UIImage.SymbolConfiguration(pointSize: size, weight: .medium)
                b.setImage(
                    UIImage(systemName: name, withConfiguration: cfg)?
                        .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal),
                    for: .normal)
                b.addTarget(self, action: #selector(captureSelectionBeforeToolbar), for: .touchDown)
                b.addTarget(self, action: action, for: .touchUpInside)
                return b
            }

            var x: CGFloat = 12
            let btnW: CGFloat = 62

            func addButton(_ btn: UIButton) {
                btn.frame = CGRect(x: x, y: 0, width: btnW, height: pillH)
                scroll.addSubview(btn)
                x += btnW
            }

            @discardableResult
            func separator() -> UIView {
                let v = UIView(frame: CGRect(x: x + 4, y: (pillH - 28) / 2, width: 1, height: 28))
                v.backgroundColor = UIColor.separator
                scroll.addSubview(v)
                x += 10
                return v
            }

            let bPaste = symbolButton("doc.on.clipboard", action: #selector(paste))
            addButton(bPaste); btnPaste = bPaste
            separator()

            // Single button for B/I/U/S — dropdown menu like the color highlighter.
            // Open: `UIDeferredMenuElement.uncached` hides the pill.
            // Close: `onMenuWillEnd` restores it (covers the "tap outside" dismiss case).
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
            addButton(bTextStyle); btnTextStyle = bTextStyle

            // Highlighter button placed immediately to the right of the text-style button (no separator).
            let bColor = MenuButton(type: .custom)
            bColor.showsMenuAsPrimaryAction = true
            bColor.menu = colorMenu(current: nil)
            bColor.onMenuWillEnd = { [weak self] in
                self?.menuPresentingUntil = nil
                self?.setToolbarHidden(false)
            }
            let cfgH = UIImage.SymbolConfiguration(pointSize: iconSize, weight: .medium)
            bColor.setImage(UIImage(systemName: "highlighter", withConfiguration: cfgH)?
                .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal), for: .normal)
            addButton(bColor); btnColor = bColor

            separator()
            let bUndo = symbolButton("arrow.uturn.backward", action: #selector(toolbarUndo))
            addButton(bUndo); btnUndo = bUndo
            let bRedo = symbolButton("arrow.uturn.forward", action: #selector(toolbarRedo))
            addButton(bRedo); btnRedo = bRedo
            updateUndoRedoButtons()

            separator()
            addButton(symbolButton("return", action: #selector(toolbarLineBreak)))
            separator()
            addButton(symbolButton("keyboard.chevron.compact.down", action: #selector(dismissKeyboard)))

            scroll.contentSize = CGSize(width: x + 12, height: pillH)
            return container
        }

        @objc func captureSelectionBeforeToolbar() {
            toolbarActionInProgress = true
            guard let tv else { return }
            if tv.selectedRange.length == 0 { clearRememberedSelection() }
            rememberSelection(tv.selectedRange, length: tv.attributedText.length)
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
            // Defensive reset: `insertText` for programmatic inserts may bypass
            // `shouldChangeTextIn`, leaving `shiftEnterTyped = true`. The next Enter
            // press from the keyboard would then be treated as a line break instead
            // of splitting the block.
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

        /// Updates the undo/redo button visuals using the live state from
        /// `canUndoProvider`/`canRedoProvider`. Called from `updateUIView`,
        /// `textViewDidChange`, and `textViewDidChangeSelection` to cover
        /// SwiftUI re-renders, typing, and undo/redo respectively.
        /// Caches the last known state to avoid recreating `UIImage` on every keystroke.
        fileprivate func updateUndoRedoButtons() {
            let cU = parent.canUndoProvider?() ?? false
            let cR = parent.canRedoProvider?() ?? false
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
        private func applyColor(_ name: String) { applyStyle(.color(name)) }

        private func clearColor() {
            defer { toolbarActionInProgress = false }
            guard let tv, let attr = tv.attributedText else { return }
            let range = selectionForToolbar(currentSelection: tv.selectedRange, length: attr.length)
            guard range.length > 0 else {
                var attrs = tv.typingAttributes
                attrs.removeValue(forKey: .pinkhaColor)
                attrs[.foregroundColor] = UIColor.label
                tv.typingAttributes = attrs
                pendingColor = nil
                updateToolbar()
                clearRememberedSelection()
                _ = tv.becomeFirstResponder()
                return
            }
            let m = NSMutableAttributedString(attributedString: attr)
            m.removeAttribute(.pinkhaColor, range: range)
            m.addAttribute(.foregroundColor, value: UIColor.label, range: range)
            tv.textStorage.beginEditing()
            tv.textStorage.setAttributedString(m)
            tv.textStorage.endEditing()
            tv.selectedRange = range
            rememberSelection(range, length: m.length)
            save(attributedToSpans(tv.attributedText, police: parent.baseFont))
            updateToolbar()
        }

        private func applyStyle(_ style: InlineStyleFfi) {
            defer { toolbarActionInProgress = false }
            guard let tv, let attr = tv.attributedText else { return }
            let range = selectionForToolbar(currentSelection: tv.selectedRange, length: attr.length)

            guard range.length > 0 else {
                applyStyleTyping(tv: tv, style: style)
                return
            }

            let m = NSMutableAttributedString(attributedString: attr)

            switch style {
            case .bold:
                let allBold = entireRange(in: attr, range: range, check: attrsContainBold)
                attr.enumerateAttribute(.font, in: range) { _, r, _ in
                    let italic = attrsContainItalic(in: attr, position: r.location)
                    m.addAttribute(.font, value: fontWithTraits(parent.baseFont, bold: !allBold, italic: italic), range: r)
                    if italic { m.addAttribute(.pinkhaObliqueness, value: 0.2, range: r) }
                    else       { m.removeAttribute(.pinkhaObliqueness, range: r) }
                }
                if !allBold { m.addAttribute(.pinkhaBold,    value: true, range: range) }
                else         { m.removeAttribute(.pinkhaBold,              range: range) }

            case .italic:
                let allItalic = entireRange(in: attr, range: range, check: attrsContainItalic)
                attr.enumerateAttribute(.font, in: range) { _, r, _ in
                    let bold = attrsContainBold(in: attr, position: r.location)
                    m.addAttribute(.font, value: fontWithTraits(parent.baseFont, bold: bold, italic: !allItalic), range: r)
                }
                if !allItalic {
                    m.addAttribute(.pinkhaItalic, value: true, range: range)
                    m.addAttribute(.pinkhaObliqueness, value: 0.2, range: range)
                } else {
                    m.removeAttribute(.pinkhaItalic, range: range)
                    m.removeAttribute(.pinkhaObliqueness, range: range)
                }

            case .underline:
                let already = attr.attribute(.underlineStyle, at: range.location, effectiveRange: nil) != nil
                if already { m.removeAttribute(.underlineStyle, range: range) }
                else    { m.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }

            case .strikethrough:
                let already = attr.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) != nil
                if already { m.removeAttribute(.strikethroughStyle, range: range) }
                else    { m.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }

            case .color(let nom):
                let current = attr.attribute(.pinkhaColor, at: range.location, effectiveRange: nil) as? String
                if current == nom {
                    m.removeAttribute(.foregroundColor, range: range)
                    m.removeAttribute(.pinkhaColor,     range: range)
                    m.addAttribute(.foregroundColor, value: UIColor.label, range: range)
                } else {
                    m.addAttribute(.foregroundColor, value: uiColorFromName(nom), range: range)
                    m.addAttribute(.pinkhaColor,     value: nom,                     range: range)
                }
            default: break
            }

            tv.textStorage.beginEditing()
            tv.textStorage.setAttributedString(m)
            tv.textStorage.endEditing()
            tv.selectedRange  = range
            rememberSelection(range, length: m.length)
            save(attributedToSpans(tv.attributedText, police: parent.baseFont))
            updateToolbar()
            // The color menu (showsMenuAsPrimaryAction) resigns first responder;
            // restore it to keep the keyboard and the selection visible.
            _ = tv.becomeFirstResponder()
        }

        private func applyStyleTyping(tv: UITextView, style: InlineStyleFfi) {
            var attrs = tv.typingAttributes
            switch style {
            case .bold:
                let bold   = attrsContainBold(attrs)
                let italic = attrsContainItalic(attrs)
                attrs[.font] = fontWithTraits(parent.baseFont, bold: !bold, italic: italic)
                if !bold { attrs[.pinkhaBold] = true } else { attrs.removeValue(forKey: .pinkhaBold) }
                if italic { attrs[.pinkhaObliqueness] = 0.2 }
                else      { attrs.removeValue(forKey: .pinkhaObliqueness) }
            case .italic:
                let bold   = attrsContainBold(attrs)
                let italic = attrsContainItalic(attrs)
                attrs[.font] = fontWithTraits(parent.baseFont, bold: bold, italic: !italic)
                if !italic {
                    attrs[.pinkhaItalic] = true
                    attrs[.pinkhaObliqueness] = 0.2
                } else {
                    attrs.removeValue(forKey: .pinkhaItalic)
                    attrs.removeValue(forKey: .pinkhaObliqueness)
                }
            case .underline:
                if attrs[.underlineStyle] != nil { attrs.removeValue(forKey: .underlineStyle) }
                else { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            case .strikethrough:
                if attrs[.strikethroughStyle] != nil { attrs.removeValue(forKey: .strikethroughStyle) }
                else { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            case .color(let nom):
                // Source of truth: pendingColor (typingAttributes is reset by
                // textViewDidBeginEditing after the menu closes).
                let currentColor = pendingColor ?? (attrs[.pinkhaColor] as? String)
                if currentColor == nom {
                    attrs.removeValue(forKey: .pinkhaColor)
                    attrs[.foregroundColor] = UIColor.label
                    pendingColor = nil
                } else {
                    attrs[.foregroundColor] = uiColorFromName(nom)
                    attrs[.pinkhaColor]     = nom
                    pendingColor = nom
                }
            default: break
            }
            tv.typingAttributes = attrs
            updateToolbar()
            clearRememberedSelection()
            _ = tv.becomeFirstResponder()
        }

        private func rememberSelection(_ range: NSRange, length: Int) {
            let selection = normalizedSelection(range, length: length)
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

            let bold: Bool; let italic: Bool; let underline: Bool; let strike: Bool; let color: String?
            if range.length > 0, range.location < len {
                let loc = min(range.location, len - 1)
                bold     = entireRange(in: attr, range: range, check: attrsContainBold)
                italic   = entireRange(in: attr, range: range, check: attrsContainItalic)
                underline = attr.attribute(.underlineStyle,     at: loc, effectiveRange: nil) != nil
                strike   = attr.attribute(.strikethroughStyle, at: loc, effectiveRange: nil) != nil
                color  = attr.attribute(.pinkhaColor,        at: loc, effectiveRange: nil) as? String
            } else {
                let attrs = tv.typingAttributes
                bold     = attrsContainBold(attrs)
                italic   = attrsContainItalic(attrs)
                underline = attrs[.underlineStyle]     != nil
                strike   = attrs[.strikethroughStyle]  != nil
                // pendingColor takes priority: typingAttributes is reset by
                // textViewDidBeginEditing after the menu, but typing-color mode stays active.
                color  = pendingColor ?? (attrs[.pinkhaColor] as? String)
            }

            updateTextStyleButton(bold: bold, italic: italic, underline: underline, strike: strike)
            updateColorButton(color)

            updatePasteButton()
        }


        private func setSymbolActive(_ btn: UIButton?, active: Bool, name: String, size: CGFloat = 22) {
            guard let btn else { return }
            let c: UIColor = active ? (UIColor(named: "Accent") ?? .tintColor) : .secondaryLabel
            let cfg = UIImage.SymbolConfiguration(pointSize: size, weight: .medium)
            btn.setImage(UIImage(systemName: name, withConfiguration: cfg)?
                .withTintColor(c, renderingMode: .alwaysOriginal), for: .normal)
        }

        // Color dropdown menu. Content is computed lazily via `UIDeferredMenuElement.uncached`:
        // the closure runs each time the user opens the menu — this is the reliable hook
        // for hiding the pill at the exact moment of presentation (`.touchDown` is consumed
        // by the gesture recognizer of `showsMenuAsPrimaryAction`).
        private func colorMenu(current: String?) -> UIMenu {
            let deferred = UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else { completion([]); return }
                self.captureSelectionBeforeToolbar()
                self.menuPresentingUntil = Date().addingTimeInterval(0.7)
                self.setToolbarHidden(true)
                completion(self.colorMenuChildren(current: current))
            }
            return UIMenu(title: "", children: [deferred])
        }

        private func colorMenuChildren(current: String?) -> [UIMenuElement] {
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

            let none = UIAction(
                title: "Aucune",
                image: UIImage(systemName: "xmark", withConfiguration: cfgX)
            ) { [weak self] _ in
                self?.clearColor()
                self?.menuPresentingUntil = nil
                self?.setToolbarHidden(false)
            }
            if current == nil { none.state = .on }

            let items = palette.map { (nom, couleur, label) -> UIAction in
                let img = UIImage(systemName: "circle.fill", withConfiguration: cfgDot)?
                    .withTintColor(couleur, renderingMode: .alwaysOriginal)
                let action = UIAction(title: label, image: img) { [weak self] _ in
                    self?.applyColor(nom)
                    self?.menuPresentingUntil = nil
                    self?.setToolbarHidden(false)
                }
                if current == nom { action.state = .on }
                return action
            }
            return [none] + items
        }

        private func updateColorButton(_ current: String?) {
            guard let btn = btnColor else { return }
            let iconName = current != nil ? "highlighter.badge.ellipsis" : "highlighter"
            let c: UIColor = current.map { uiColorFromName($0) } ?? .secondaryLabel
            let cfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
            btn.setImage(UIImage(systemName: iconName, withConfiguration: cfg)?
                .withTintColor(c, renderingMode: .alwaysOriginal), for: .normal)
            btn.menu = colorMenu(current: current)
        }

        // Same pattern for B/I/U/S — deferred element for the reliable presentation hook.
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
                let selection = self.normalizedSelection(textView.selectedRange, length: textView.attributedText.length)
                if self.selectionGeneration == generation && !self.toolbarActionInProgress && selection.length == 0 {
                    self.clearRememberedSelection()
                }
            }
        }

        /// Returns the selection to use for a toolbar action: the current selection if non-empty,
        /// otherwise the last remembered non-empty selection (set before the menu was opened).
        private func selectionForToolbar(currentSelection: NSRange, length: Int) -> NSRange {
            let current = normalizedSelection(currentSelection, length: length)
            if current.length > 0 { return current }
            let remembered = normalizedSelection(lastSelection, length: length)
            return remembered.length > 0 ? remembered : current
        }

        private func normalizedSelection(_ range: NSRange, length: Int) -> NSRange {
            guard range.location != NSNotFound, range.location <= length else {
                return NSRange(location: length, length: 0)
            }
            let end = min(range.location + range.length, length)
            return NSRange(location: range.location, length: max(0, end - range.location))
        }

        /// Returns `true` if `check` is satisfied for every attribute run in `range`.
        private func entireRange(
            in attr: NSAttributedString,
            range: NSRange,
            check: ([NSAttributedString.Key: Any]) -> Bool
        ) -> Bool {
            guard range.length > 0 else { return false }
            var result = true
            attr.enumerateAttributes(in: range) { attrs, _, stop in
                if !check(attrs) {
                    result = false
                    stop.pointee = true
                }
            }
            return result
        }

        private func attrsContainBold(in attr: NSAttributedString, position: Int) -> Bool {
            attrsContainBold(attr.attributes(at: position, effectiveRange: nil))
        }

        private func attrsContainItalic(in attr: NSAttributedString, position: Int) -> Bool {
            attrsContainItalic(attr.attributes(at: position, effectiveRange: nil))
        }

        private func attrsContainBold(_ attrs: [NSAttributedString.Key: Any]) -> Bool {
            if (attrs[.pinkhaBold] as? Bool) == true { return true }
            // Fall back to the font's symbolic traits: UIKit strips custom attributes from
            // typingAttributes after insertion, but the bold font descriptor remains reliable.
            // Compare against baseFont to avoid marking a heading (already bold by design)
            // as user-applied bold.
            guard let f = attrs[.font] as? UIFont else { return false }
            return f.fontDescriptor.symbolicTraits.contains(.traitBold)
                && !parent.baseFont.fontDescriptor.symbolicTraits.contains(.traitBold)
        }

        private func attrsContainItalic(_ attrs: [NSAttributedString.Key: Any]) -> Bool {
            if (attrs[.pinkhaItalic] as? Bool) == true { return true }
            guard let f = attrs[.font] as? UIFont else { return false }
            return f.fontDescriptor.symbolicTraits.contains(.traitItalic)
                && !parent.baseFont.fontDescriptor.symbolicTraits.contains(.traitItalic)
        }
    }
}
