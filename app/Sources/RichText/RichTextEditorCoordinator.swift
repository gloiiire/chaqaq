import UIKit
import SwiftUI

// ── Coordinator RichTextEditor ────────────────────────────────────────────────

/// Coordinator for `RichTextEditor`: UITextView delegate + pill toolbar manager.
/// Defined at module level to allow extensions in separate files.
final class RichTextEditorCoordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {

    var parent: RichTextEditor
    weak var tv: ExpandingTextView?
    var isEditing = false
    var isDeleting = false
    var shiftEnterTyped = false
    var lastSelection = NSRange(location: 0, length: 0)
    // Active typing color without a selection: UIKit resets typingAttributes
    // after each character (and opening a menu may resign first responder),
    // so we re-inject the color just before each insertion.
    var pendingColor: String? = nil
    var toolbarActionInProgress = false
    var selectionGeneration = 0
    weak var btnTextStyle: UIButton?
    weak var btnColor: UIButton?
    weak var btnBlockColor: UIButton?
    weak var btnPaste: UIButton?
    weak var btnUndo: UIButton?
    weak var btnRedo: UIButton?
    var lastCanUndo: Bool?
    var lastCanRedo: Bool?
    /// Spans already synced with the text view — allows skipping the `spansToAttributed`
    /// recomputation during SwiftUI re-renders where this block's spans have not changed.
    var lastSyncedSpans: [InlineTextFfi]?
    /// Mirror of `parent.blockColor` at last `updateUIView` recompute. Lets us
    /// detect "spans unchanged but block colour changed" — without this guard
    /// the user has to leave and re-enter the note for the new block colour to
    /// render, because the spans-equality check skips the `spansToAttributed`
    /// rebuild.
    var lastSyncedBlockColor: String?
    // The pill toolbar — animated to alpha 0 when a dropdown menu opens
    // (Notes.app style: the toolbar fades while the menu is visible).
    weak var toolbarPill: UIView?
    var toolbarHidden = false
    // Guard window: for ~700 ms after a menu opens, ignore spurious
    // `textViewDidChangeSelection` events UIKit emits during presentation
    // (otherwise the pill flickers or never hides).
    var menuPresentingUntil: Date?

    init(parent: RichTextEditor) {
        self.parent = parent
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pasteboardChanged),
            name: UIPasteboard.changedNotification,
            object: nil)
    }

    @objc func pasteboardChanged() {
        DispatchQueue.main.async { [weak self] in self?.updatePasteButton() }
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

    // ── UITextViewDelegate ────────────────────────────────────────────────────

    func textViewDidBeginEditing(_ tv: UITextView) {
        isEditing = true
        parent.isFocused = true
        rememberSelection(tv.selectedRange, length: tv.attributedText.length)
        // Default foreground: block-level colour when set, otherwise the
        // standard label colour. This is what newly typed text inherits.
        // Without this, typing in a coloured block would produce white text
        // because UIKit would use the bare `UIColor.label` default.
        let defaultForeground: UIColor = parent.blockColor.map(uiColorFromName) ?? .label
        // Clear the placeholder when editing begins.
        if tv.textColor == .tertiaryLabel {
            tv.attributedText = NSAttributedString(string: "", attributes: [
                .font: parent.baseFont,
                .foregroundColor: defaultForeground
            ])
        }
        tv.typingAttributes = [.font: parent.baseFont, .foregroundColor: defaultForeground]
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
        // If the user closed a menu (tap in text → selection changed),
        // restore the pill in case it is still hidden.
        // Skip during the guard window to avoid cancelling the requested hide.
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
        // Backspace at the start of a non-empty block → merge with the previous block
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
                // Shift+Enter: let the line break insert normally
                shiftEnterTyped = false
                return true
            }
            // Normal Enter: split the block and create a new one.
            // Preserve the attributes (color, bold…) of the portion after the cursor.
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
        // If the UITextView is being detached from the view hierarchy (a
        // structural mutation like indent/outdent shrank the parent's array
        // and SwiftUI is in the middle of removing this view), the indexed
        // bindings into `vm.blocks` are stale — reading or writing them
        // crashes with "Index out of range". Skip the persistence and
        // placeholder restore in that case; the new view that replaces this
        // one will render the correct content from the fresh array.
        guard tv.window != nil else { return }
        save(attributedToSpans(tv.attributedText, police: parent.baseFont))
        // Use the UITextView's own state instead of reading `parent.spans` —
        // the latter accesses an indexed Binding that may also be stale even
        // when the window check above let us through (e.g. SwiftUI between
        // renders).
        if tv.attributedText.string.isEmpty { tv.attributedText = placeholder() }
    }

    /// Intercepts taps / long-press-then-open on links inside the editor.
    /// Returns `false` to suppress UIKit's default behaviour (opening the
    /// URL externally) when the scheme is `pinkha://` — we hand the path off
    /// to the SwiftUI parent, which navigates to the matching document.
    func textView(_ tv: UITextView,
                  shouldInteractWith url: URL,
                  in characterRange: NSRange,
                  interaction: UITextItemInteraction) -> Bool {
        guard interaction == .invokeDefaultAction else { return true }
        if url.scheme == "pinkha", url.host == "doc" {
            // Path format: `/{uuid}` — strip the leading slash.
            let uuid = url.path.dropFirst()
            guard !uuid.isEmpty else { return true }
            parent.onOpenInternalDoc?(String(uuid))
            return false
        }
        return true
    }

    func textViewDidChange(_ tv: UITextView) {
        let text = tv.text ?? ""

        if let shortcut = markdownShortcut(for: text) {
            parent.onConvert?(shortcut)
            return
        }

        // save() = update parent.spans + call onSaveSpans → vm.saveBlock → capture the burst anchor for undo.
        // Called on every keystroke so that canUndo is true from the first character.
        save(attributedToSpans(tv.attributedText, police: parent.baseFont))
        if tv.selectedRange.length == 0 { clearRememberedSelection() }
        tv.invalidateIntrinsicContentSize()
        updateUndoRedoButtons()
    }

    // ── Save ──────────────────────────────────────────────────────────────────

    func save(_ spans: [InlineTextFfi]) {
        // When `onSaveSpans` is wired (block editors), prefer the ID-safe
        // callback path: the VM looks up the block by ID, updates its `spans`,
        // and the @Published change re-renders the editor. Writing
        // `parent.spans = spans` directly would crash with "Index out of
        // range" after a structural mutation (indent/outdent/delete) because
        // the binding still points at a stale array index — `textViewDidEndEditing`
        // can fire AFTER the array has shrunk.
        //
        // When `onSaveSpans` is nil (title editor, anything bound to a
        // non-array @State), the binding write is the only way for the parent
        // to learn about the new spans.
        if let onSaveSpans = parent.onSaveSpans {
            onSaveSpans(spans)
        } else {
            parent.spans = spans
            parent.onSave?()
        }
    }
}
