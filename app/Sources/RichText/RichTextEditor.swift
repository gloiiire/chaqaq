import SwiftUI
import UIKit

// ── RichTextEditor ────────────────────────────────────────────────────────────

/// `UIViewRepresentable` wrapping `ExpandingTextView` with full rich text editing:
/// bold/italic/underline/strikethrough/color/link via a glass pill toolbar,
/// markdown shortcuts, Shift+Enter line breaks, and undo/redo integration.
struct RichTextEditor: UIViewRepresentable {
    typealias Coordinator = RichTextEditorCoordinator

    @Binding var spans: [InlineTextFfi]
    @Binding var isFocused: Bool
    @Environment(\.isEnabled) var isEnabled
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
    // textViewDidChange and textViewDidChangeSelection — covers typing, undo/redo
    // and selection changes.
    var onUndo: (() -> Void)? = nil
    var onRedo: (() -> Void)? = nil
    var canUndoProvider: (() -> Bool)? = nil
    var canRedoProvider: (() -> Bool)? = nil
    /// Indent / outdent the *current block* (whichever owns this editor view).
    /// The DocumentView owns the block identity, so it wires the closure to
    /// call the right FFI on the right block. `nil` = button disabled.
    var onIndent: (() -> Void)? = nil
    var onOutdent: (() -> Void)? = nil
    /// Block-level text color name (matches the Rust `Block.color` field).
    /// `spansToAttributed` uses it as the default foreground when a span has
    /// no inline `.color(...)` override — implements the "inline wins over
    /// block" priority rule from the domain.
    var blockColor: String? = nil
    /// Called when the user picks a colour from the ¶ menu (or "None" to
    /// clear). Goes through the VM which calls the FFI `set_block_color`.
    var onSetBlockColor: ((String?) -> Void)? = nil
    /// Called when the user taps a `pinkha://doc/{uuid}` link in the
    /// editor — the value is the destination document UUID. The parent
    /// view (DocumentView) navigates to that document instead of opening
    /// the URL in Safari. Notion mentions rewritten at import time
    /// (`feat: 2-pass Notion mention rewrite`) are the main producer of
    /// these URLs.
    var onOpenInternalDoc: ((String) -> Void)? = nil

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
        tv.onNavigateNext      = { [weak coord] in coord?.parent.onNavigateNext?() }
        tv.onStopNavigationRepeat = { [weak coord] in coord?.parent.onStopNavigationRepeat?() }
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(RichTextEditorCoordinator.handleLongPressSelection(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.cancelsTouchesInView = false
        longPress.delegate = context.coordinator
        tv.addGestureRecognizer(longPress)
        if spans.isEmpty { tv.attributedText = context.coordinator.placeholder() }
        else { tv.attributedText = withExtras(spansToAttributed(spans, police: baseFont, blockColor: blockColor)) }
        return tv
    }

    func updateUIView(_ tv: ExpandingTextView, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        coord.updateUndoRedoButtons()
        coord.updateBlockColorButton(blockColor)
        tv.tintColor = pinkhaSelectionTint
        tv.isEditable = isEnabled
        tv.isSelectable = isEnabled
        if !isEnabled && tv.isFirstResponder {
            tv.resignFirstResponder()
            DispatchQueue.main.async { isFocused = false }
        }

        // Skip recomputation when spans have not changed: SwiftUI re-renders
        // the whole ForEach on every keystroke (typically for a single block); no need
        // to rebuild NSAttributedString for the N-1 other unchanged blocks.
        // We also recompute when `blockColor` flips — else the user would
        // have to leave the note and come back to see the new colour, because
        // the spans-equality check would skip the `spansToAttributed` rebuild.
        if coord.lastSyncedSpans != spans
            || coord.lastSyncedBlockColor != blockColor
            || coord.lastSyncedIsEnabled != isEnabled {
            // Do not reassign tv.font during editing: UITextView.font reapplies
            // the font to ALL the text and would erase per-character bold/italic.
            let editingText: NSAttributedString = spans.isEmpty
                ? NSAttributedString(string: "",
                                      attributes: [.font: baseFont, .foregroundColor: UIColor.label])
                : withExtras(spansToAttributed(spans, police: baseFont, blockColor: blockColor))
            if !coord.isEditing {
                tv.font = baseFont
                tv.attributedText = spans.isEmpty ? coord.placeholder() : editingText
            } else if tv.attributedText.string != editingText.string
                        || coord.lastSyncedBlockColor != blockColor {
                // Two reasons to refresh during editing:
                //  - Text string changed (undo/redo applied via the VM).
                //  - Block colour changed: the string is identical but the
                //    default foreground attribute differs. Without this branch
                //    the ¶ palette wouldn't take effect until the user left
                //    and re-entered the note.
                // Preserve the cursor position when only attributes changed;
                // jump to the end on a string-level edit (undo/redo).
                var savedTyping = tv.typingAttributes
                // When the block colour just flipped AND the user has no
                // pending inline colour active, update the default foreground
                // in `typingAttributes` so the *next* keystroke inherits the
                // new block colour instead of staying on the previous value
                // (typically UIColor.label = white in dark mode).
                if coord.lastSyncedBlockColor != blockColor && coord.pendingColor == nil
                    && savedTyping[.pinkhaColor] == nil {
                    savedTyping[.foregroundColor] = blockColor.map(uiColorFromName) ?? UIColor.label
                }
                let savedSelection = tv.selectedRange
                let stringChanged = tv.attributedText.string != editingText.string
                tv.attributedText = editingText
                tv.typingAttributes = savedTyping
                tv.selectedRange = stringChanged
                    ? NSRange(location: editingText.length, length: 0)
                    : savedSelection
            }
            coord.lastSyncedSpans = spans
            coord.lastSyncedBlockColor = blockColor
            coord.lastSyncedIsEnabled = isEnabled
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

    /// Overlays `extraAttrs` (e.g. strikethrough for todo) on top of the span-derived attributes.
    private func withExtras(_ attr: NSAttributedString) -> NSAttributedString {
        guard let extras = extraAttrs, !extras.isEmpty else { return attr }
        let m = NSMutableAttributedString(attributedString: attr)
        m.addAttributes(extras, range: NSRange(location: 0, length: m.length))
        return m
    }

    func makeCoordinator() -> RichTextEditorCoordinator { RichTextEditorCoordinator(parent: self) }
}
