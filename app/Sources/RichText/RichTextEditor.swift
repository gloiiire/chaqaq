import SwiftUI
import UIKit
import PinkhaFFI
import PinkhaCore

// ── RichTextEditor ────────────────────────────────────────────────────────────

/// `UIViewRepresentable` wrapping `ExpandingTextView` with full rich text editing:
/// bold/italic/underline/strikethrough/color/link via a glass pill toolbar,
/// markdown shortcuts, Shift+Enter line breaks, and undo/redo integration.
/// One row in the `@`-mention picker — a document the user can
/// reference by name. The picker shows `title` and on tap inserts
/// a `pinkha://doc/{id}` link with `title` as the visible text.
struct MentionCandidate {
    let id: String
    let title: String
}

struct RichTextEditor: UIViewRepresentable {
    typealias Coordinator = RichTextEditorCoordinator

    @Binding var spans: [InlineTextFfi]
    @Binding var isFocused: Bool
    @Environment(\.isEnabled) var isEnabled
    @Environment(AppSettings.self) var settings
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
    /// Accent color used by the keyboard pill's "active" icon tint
    /// (paste when clipboard has strings, etc.). Caller resolves it
    /// — typically a per-doc override via `DocumentView.effectiveAccentColor`,
    /// falling back to the app-wide accent. `nil` keeps the legacy
    /// `UIColor(named: "Accent") ?? .tintColor` path.
    var accentColor: UIColor? = nil
    /// Called when the user picks a colour from the ¶ menu (or "None" to
    /// clear). Goes through the VM which calls the FFI `set_block_color`.
    var onSetBlockColor: ((String?) -> Void)? = nil
    /// Block-level *background* color name (Craft / Notion highlight).
    /// Mirrors `blockColor` — passed down so the keyboard pill's
    /// background-color button can highlight the active swatch.
    var blockBackgroundColor: String? = nil
    /// Background-color setter — same shape as `onSetBlockColor`,
    /// routes through the VM to FFI `set_block_background_color`.
    var onSetBlockBackgroundColor: ((String?) -> Void)? = nil
    /// Resolved writing direction for this block (`"ltr"` / `"rtl"`),
    /// already combined from per-block override + document default
    /// at the call site. `nil` leaves UIKit's default `.natural`
    /// alignment, which honours the system locale.
    var textDirection: String? = nil
    /// Books-style theme foreground colour passed down so the spans
    /// inherit the right default (papier = black, calme/attention =
    /// dark brown, tranquille = off-white, …). `nil` keeps the
    /// system `.label` fallback.
    var themeForegroundColor: UIColor? = nil
    /// Forced keyboard appearance — `.dark` for dark themes,
    /// `.light` for light themes, `.default` to follow the window's
    /// trait collection. Setting this explicitly is what fixes the
    /// disconnect between the doc background and the on-screen
    /// keyboard when a per-doc theme overrides the global one (the
    /// keyboard lives in its own window and doesn't pick up the
    /// app-window `overrideUserInterfaceStyle` we just set).
    var keyboardAppearance: UIKeyboardAppearance = .default
    /// Provides the candidate documents for the `@`-mention picker.
    /// Called when the user types `@` at the start of a word — the
    /// coordinator shows the returned list as a chooser; tapping
    /// an entry replaces the `@…` token with a `pinkha://doc/{id}`
    /// link styled with the document's title. `nil` disables the
    /// feature (e.g. title editor, where mentions don't make sense).
    var onMentionLookup: (() -> [MentionCandidate])? = nil
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
        tv.tintColor = resolvedSelectionTint(settings)
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
        else { tv.attributedText = withExtras(spansToAttributed(spans, police: baseFont, blockColor: blockColor, themeForeground: themeForegroundColor)) }
        return tv
    }

    func updateUIView(_ tv: ExpandingTextView, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        // Gate every setter behind an equality check : SwiftUI calls
        // `updateUIView` for ALL rows on every parent re-render, even
        // when the row's own props are unchanged. Unconditionally
        // touching `tintColor` / `textAlignment` / `semanticContent…`
        // / pushing a new accent → UIImage rebuild forces a layout
        // pass per row per frame and is the dominant source of
        // scroll jank in the editor (verified by an audit). The
        // checks themselves are nanoseconds; the avoided work is ms.
        if coord.lastSyncedBlockColor != blockColor {
            coord.updateBlockColorButton(blockColor)
        }
        if coord.lastSyncedBlockBackgroundColor != blockBackgroundColor {
            coord.updateBlockBackgroundColorButton(blockBackgroundColor)
            coord.lastSyncedBlockBackgroundColor = blockBackgroundColor
        }
        if coord.lastSyncedTextDirection != textDirection {
            switch textDirection {
            case "rtl":
                tv.textAlignment = .right
                tv.semanticContentAttribute = .forceRightToLeft
            case "ltr":
                tv.textAlignment = .left
                tv.semanticContentAttribute = .forceLeftToRight
            default:
                tv.textAlignment = .natural
                tv.semanticContentAttribute = .unspecified
            }
            coord.lastSyncedTextDirection = textDirection
        }
        if coord.currentAccentColor != accentColor {
            coord.currentAccentColor = accentColor
            coord.updatePasteButton()
        }
        let tint = resolvedSelectionTint(settings)
        if tv.tintColor != tint { tv.tintColor = tint }
        // Pin link colour to the theme foreground (or `.label`) instead
        // of letting UIKit derive it from `tintColor` — which can drift
        // to white / black depending on selection-tint settings and
        // leave links invisible against the doc background (e.g. a
        // YouTube URL going black on a dark doc). The link attributes
        // are merged with each `.link` attribute on the spans.
        let linkColor: UIColor = themeForegroundColor ?? .label
        let linkAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        if (tv.linkTextAttributes?[.foregroundColor] as? UIColor) != linkColor {
            tv.linkTextAttributes = linkAttrs
        }
        if tv.isEditable != isEnabled { tv.isEditable = isEnabled }
        if tv.isSelectable != isEnabled { tv.isSelectable = isEnabled }
        if tv.keyboardAppearance != keyboardAppearance {
            tv.keyboardAppearance = keyboardAppearance
            // The text view needs to be told the input view changed
            // so iOS re-renders the keyboard with the new appearance
            // while it's already on screen — otherwise the swap only
            // takes effect the *next* time the keyboard is shown.
            if tv.isFirstResponder { tv.reloadInputViews() }
        }
        // Hard iOS limitation — the keyboard host window lives in
        // another process (`UIRemoteKeyboardWindow`) and only takes
        // `.light` / `.dark` via `keyboardAppearance`. Tinting the
        // accessory container in the doc theme worked visually but
        // hid scrolling text behind the opaque strip, which was
        // worse than the seam. Native apps (Notion, Craft, Bear)
        // accept the seam too. Confirmed in Apple forum #707262.
        // Undo / redo button visuals already have an internal cache
        // (see `RichTextEditorCoordinator.lastCanUndo`) — leave the
        // call here so the buttons stay live during edits.
        coord.updateUndoRedoButtons()
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
            || coord.lastSyncedIsEnabled != isEnabled
            || coord.lastSyncedThemeForeground != themeForegroundColor {
            // Do not reassign tv.font during editing: UITextView.font reapplies
            // the font to ALL the text and would erase per-character bold/italic.
            let editingText: NSAttributedString = spans.isEmpty
                ? NSAttributedString(string: "",
                                      attributes: [.font: baseFont,
                                                   .foregroundColor: themeForegroundColor ?? UIColor.label])
                : withExtras(spansToAttributed(spans, police: baseFont, blockColor: blockColor, themeForeground: themeForegroundColor))
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
            coord.lastSyncedThemeForeground = themeForegroundColor
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
