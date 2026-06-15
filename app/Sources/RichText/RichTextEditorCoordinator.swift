import UIKit
import SwiftUI
import PinkhaFFI

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
    /// Twin of `btnBlockColor` for the block-level *background* color
    /// (Craft / Notion highlight). Lives right next to ¶ in the
    /// keyboard pill; the SwiftUI parent pushes its current value via
    /// `updateUIView` so the swatch / active highlight stays fresh.
    weak var btnBlockBg: UIButton?
    weak var btnPaste: UIButton?
    /// Pushed by the SwiftUI parent on every `updateUIView` —
    /// `setSymbolActive(...)` reads it to paint "active" toolbar
    /// icons in the per-doc accent (or the global one when no
    /// override is set). `nil` falls back to `UIColor(named: "Accent")`.
    var currentAccentColor: UIColor?
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
    /// Mirror of `parent.blockBackgroundColor` for the same
    /// re-render-gating reason. Without this guard,
    /// `updateBlockBackgroundColorButton` rebuilds a fresh UIImage
    /// every `updateUIView`, multiplied across every row, multiplied
    /// across every scroll frame.
    var lastSyncedBlockBackgroundColor: String?
    /// Mirror of `parent.textDirection`. Touching `tv.textAlignment`
    /// or `tv.semanticContentAttribute` triggers a full layout pass
    /// on the UITextView — way too expensive to do on every row on
    /// every render. The guard makes it a no-op when nothing changed.
    var lastSyncedTextDirection: String?
    /// Mirror of `parent.themeForegroundColor`. When the user flips the
    /// Books-style theme, the spans need to be re-rendered with the
    /// new default foreground — but the spans-equality short-circuit
    /// would otherwise skip the rebuild.
    var lastSyncedThemeForeground: UIColor?
    /// Mirror of `parent.isEnabled` (lock state). When the user locks the
    /// page, empty blocks should hide their placeholder — but the spans-
    /// equality short-circuit otherwise prevents the recompute, leaving the
    /// stale placeholder visible until the user scrolls or closes the note.
    /// Tracked here so `updateUIView` can force the refresh on flip.
    var lastSyncedIsEnabled: Bool?
    // The pill toolbar — animated to alpha 0 when a dropdown menu opens
    // (Notes.app style: the toolbar fades while the menu is visible).
    weak var toolbarPill: UIView?
    /// Floating chip picker for `@`-mentions. Created on first
    /// trigger, kept around (hidden) for subsequent triggers.
    weak var mentionBar: MentionBar?
    /// Anchors the live mention session. `start` is the offset of
    /// the `@` character, the query is everything typed after it.
    /// `nil` when no mention is in progress.
    struct MentionSession {
        let start: Int
        var queryLength: Int
        var candidates: [MentionCandidate]
    }
    var mentionSession: MentionSession?
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

    /// Disable the system long-press menu on links inside the
    /// `UITextView`. Tap is already routed through
    /// `shouldInteractWith` above, so iOS's "Copy link / Open / Share"
    /// menu adds nothing — and on iOS 26.5 its internal range
    /// enumeration crashes with `NSRangeException` on certain attributed
    /// strings (Sentry APPLE-IOS-9). Returning `nil` here skips the
    /// menu altogether.
    func textView(_ textView: UITextView,
                  menuConfigurationFor textItem: UITextItem,
                  defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
        return nil
    }

    /// Handles taps on inline text items. On iOS 17+ this is the
    /// only path that fires inside an *editable* UITextView — the
    /// older `shouldInteractWith` delegate is silent. We route:
    ///   - `pinkha://doc/{uuid}` → parent's `onOpenInternalDoc`
    ///   - any other URL → `UIApplication.shared.open` (Safari)
    /// Non-link text items (data detectors, etc.) keep their
    /// default action.
    func textView(_ textView: UITextView,
                  primaryActionFor textItem: UITextItem,
                  defaultAction: UIAction) -> UIAction? {
        if case .link(let url) = textItem.content {
            if url.scheme == "pinkha", url.host == "doc" {
                let uuid = String(url.path.dropFirst())
                guard !uuid.isEmpty else { return defaultAction }
                return UIAction { [weak self] _ in
                    self?.parent.onOpenInternalDoc?(uuid)
                }
            }
            return UIAction { _ in
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        }
        return defaultAction
    }

    func textViewDidChange(_ tv: UITextView) {
        let text = tv.text ?? ""

        // Extract styled spans up front so the shortcut path can keep
        // bold/italic on the trailing content (e.g. `# **Hello**` →
        // H1 with the bold preserved).
        var currentSpans = attributedToSpans(tv.attributedText, police: parent.baseFont)
        if let shortcut = markdownShortcut(for: text, spans: currentSpans) {
            parent.onConvert?(shortcut)
            return
        }

        // URL auto-detect : the moment the user types a separator
        // (space or newline) right after something that parses as a
        // URL, retroactively wrap the preceding word in a `.link`
        // attribute. Inline rewrite keeps the typing flow uninterrupted
        // — no popups, no extra keystrokes — and round-trips back to
        // `InlineStyle::Link(String)` via `attributedToSpans`.
        if linkifyWordEndingAtCursor(tv) {
            currentSpans = attributedToSpans(tv.attributedText, police: parent.baseFont)
        }

        // Auto-embed : if the block now contains *only* one URL (and
        // nothing else, save for surrounding whitespace), promote it
        // to a `.embed` block. Routes through the same `onConvert`
        // path the long-press "Convert to embed" menu uses, so the
        // resulting block-content rewrite is undoable. Skipping any
        // block that has an external `pinkha://` link — those are
        // typed via the `@`-mention picker and we want them to stay
        // inline.
        if let url = soleURLForAutoEmbed(in: currentSpans) {
            Haptic.soft()
            parent.onConvert?(.embed(url: url))
            return
        }

        // `@`-mention trigger : the user just typed `@` at the start
        // of the editor or right after whitespace. Show a chooser
        // populated by the parent's `onMentionLookup`. The picked
        // doc replaces the `@` with a `pinkha://doc/{id}` link
        // carrying the doc's title.
        offerMentionIfTriggered(tv)

        // save() = update parent.spans + call onSaveSpans → vm.saveBlock → capture the burst anchor for undo.
        // Called on every keystroke so that canUndo is true from the first character.
        save(currentSpans)
        if tv.selectedRange.length == 0 { clearRememberedSelection() }
        tv.invalidateIntrinsicContentSize()
        updateUndoRedoButtons()
    }

    /// Scans the word immediately preceding the cursor when the
    /// character just typed was a whitespace separator (space /
    /// newline / tab), promotes it to a hyperlink if `NSDataDetector`
    /// recognises it as a URL, and returns `true` if it actually
    /// applied a link (so the caller re-extracts spans).
    @discardableResult
    private func linkifyWordEndingAtCursor(_ tv: UITextView) -> Bool {
        let ns = tv.attributedText.string as NSString
        let cursor = tv.selectedRange.location
        // Cursor must be right after a separator character.
        guard cursor > 0, cursor <= ns.length else { return false }
        let separators: CharacterSet = .whitespacesAndNewlines
        let prevScalar = ns.substring(with: NSRange(location: cursor - 1, length: 1)).unicodeScalars.first
        guard let s = prevScalar, separators.contains(s) else { return false }
        // Walk backwards over non-separator chars to find the word
        // start. Stop on another separator or the document start.
        var start = cursor - 1
        while start > 0 {
            let ch = ns.substring(with: NSRange(location: start - 1, length: 1))
            if let scalar = ch.unicodeScalars.first, separators.contains(scalar) { break }
            start -= 1
        }
        let wordRange = NSRange(location: start, length: cursor - 1 - start)
        guard wordRange.length >= 4 else { return false } // shortest sensible URL : a.b/
        // Skip if the word already carries a `.link` attribute (user
        // typed inside an existing link or pasted one we already
        // styled). Avoids re-stomping on attributes.
        if tv.attributedText.attribute(.link, at: wordRange.location,
                                       effectiveRange: nil) != nil {
            return false
        }
        let candidate = ns.substring(with: wordRange)
        guard let url = resolveURL(candidate) else { return false }
        let m = NSMutableAttributedString(attributedString: tv.attributedText)
        m.addAttribute(.link, value: url, range: wordRange)
        tv.textStorage.beginEditing()
        tv.textStorage.setAttributedString(m)
        tv.textStorage.endEditing()
        // The text length is unchanged, so restoring the cursor to its
        // pre-edit location keeps the typing flow intact.
        tv.selectedRange = NSRange(location: cursor, length: 0)
        return true
    }

    /// Top-level entry: starts a mention session when `@` is typed,
    /// otherwise updates / closes an in-progress one based on the
    /// text the user added or removed after the `@`.
    private func offerMentionIfTriggered(_ tv: UITextView) {
        guard parent.onMentionLookup != nil else { return }
        if let session = mentionSession {
            updateMentionSession(session, in: tv)
        } else {
            startMentionSessionIfNeeded(in: tv)
        }
    }

    /// Detects the `@` at-start-of-word pattern and, if matched,
    /// installs / shows the floating chip bar above the keyboard
    /// pill and seeds it with every candidate (unfiltered).
    private func startMentionSessionIfNeeded(in tv: UITextView) {
        let ns = tv.attributedText.string as NSString
        let cursor = tv.selectedRange.location
        guard cursor > 0, cursor <= ns.length else { return }
        let prev = ns.substring(with: NSRange(location: cursor - 1, length: 1))
        guard prev == "@" else { return }
        if cursor >= 2 {
            let before = ns.substring(with: NSRange(location: cursor - 2, length: 1))
            if let scalar = before.unicodeScalars.first,
               !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return
            }
        }
        guard let lookup = parent.onMentionLookup else { return }
        let candidates = lookup()
        guard !candidates.isEmpty else { return }
        mentionSession = MentionSession(
            start: cursor - 1, queryLength: 0, candidates: candidates,
        )
        showMentionBar(with: candidates, in: tv)
    }

    /// Mirrors the user's editing on top of the session: extends the
    /// query when they type more letters, shrinks it when they
    /// backspace, and tears the session down when they step outside
    /// the `@…` token (typing whitespace, moving the cursor away, or
    /// deleting the `@` itself).
    private func updateMentionSession(_ session: MentionSession, in tv: UITextView) {
        let ns = tv.attributedText.string as NSString
        let cursor = tv.selectedRange.location
        // Cursor must stay strictly after the `@`. If it moves to or
        // before the anchor, the session is over.
        guard cursor > session.start, session.start < ns.length else {
            endMentionSession()
            return
        }
        // The character at the anchor must still be `@`.
        let atChar = ns.substring(with: NSRange(location: session.start, length: 1))
        guard atChar == "@" else { endMentionSession(); return }
        let queryLength = cursor - session.start - 1
        // Whitespace inside the query closes the session (and leaves
        // the typed text in place — no replacement).
        let queryRange = NSRange(location: session.start + 1, length: queryLength)
        let query = ns.substring(with: queryRange)
        if query.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            endMentionSession()
            return
        }
        let filtered = session.candidates.filter {
            query.isEmpty
                || $0.title.range(of: query, options: .caseInsensitive) != nil
        }
        // Update state + UI. Empty filter = no chips, but we keep the
        // session alive so backspacing back to a matching prefix
        // brings the bar back.
        mentionSession = MentionSession(
            start: session.start,
            queryLength: queryLength,
            candidates: session.candidates,
        )
        mentionBar?.setCandidates(Array(filtered.prefix(20)))
    }

    /// Installs (or reveals) the floating bar above the keyboard
    /// pill. The bar is a subview of the input-accessory container
    /// (same view that hosts the pill), positioned with a negative
    /// `y` so it draws above the container's bounds — relies on
    /// `container.clipsToBounds = false`, set in `makeToolbar()`.
    /// Living in the same window as the pill avoids the cross-
    /// window conversion mess we hit earlier (the keyboard's
    /// `UITextEffectsWindow` is opaque to the app window).
    private func showMentionBar(with candidates: [MentionCandidate],
                                 in tv: UITextView) {
        guard let pill = toolbarPill, let container = pill.superview else { return }
        let bar: MentionBar
        if let existing = mentionBar {
            bar = existing
        } else {
            let new = MentionBar()
            new.translatesAutoresizingMaskIntoConstraints = true
            new.autoresizingMask = [.flexibleWidth]
            container.addSubview(new)
            mentionBar = new
            bar = new
        }
        bar.onPick = { [weak self] candidate in
            guard let self else { return }
            self.commitMention(candidate)
        }
        bar.setCandidates(Array(candidates.prefix(20)))
        // Position the bar just above the pill (which sits in the
        // container with a small vertical margin). Height = 44.
        let barHeight: CGFloat = 44
        let gap: CGFloat = 4
        bar.frame = CGRect(
            x: 0,
            y: pill.frame.minY - barHeight - gap,
            width: container.bounds.width,
            height: barHeight,
        )
        container.bringSubviewToFront(bar)
        bar.isHidden = false
        bar.alpha = 0
        UIView.animate(withDuration: 0.15) { bar.alpha = 1 }
    }

    /// Replaces the `@…` token by the candidate's title styled as a
    /// `pinkha://doc/{id}` link, then closes the session.
    private func commitMention(_ candidate: MentionCandidate) {
        guard let tv, let session = mentionSession else { return }
        Haptic.tap()
        let replaceRange = NSRange(location: session.start,
                                    length: 1 + session.queryLength)
        // `URL(string:)` only fails on a malformed string; the candidate
        // id is a UUID we just minted, so the primary path always works.
        // The fallback is paranoia — if it ever did fail we abort the
        // commit instead of force-unwrapping a second URL.
        guard let url = URL(string: "pinkha://doc/\(candidate.id)") else {
            return
        }
        let m = NSMutableAttributedString(attributedString: tv.attributedText)
        let replacement = NSMutableAttributedString(
            string: candidate.title,
            attributes: [
                .font: parent.baseFont,
                .foregroundColor: UIColor.label,
                .link: url,
            ],
        )
        m.replaceCharacters(in: replaceRange, with: replacement)
        tv.textStorage.beginEditing()
        tv.textStorage.setAttributedString(m)
        tv.textStorage.endEditing()
        let newCursor = replaceRange.location
            + (candidate.title as NSString).length
        tv.selectedRange = NSRange(location: newCursor, length: 0)
        save(attributedToSpans(tv.attributedText, police: parent.baseFont))
        updateToolbar()
        endMentionSession()
        _ = tv.becomeFirstResponder()
    }

    /// Tears down the active session and hides the bar.
    func endMentionSession() {
        mentionSession = nil
        guard let bar = mentionBar else { return }
        UIView.animate(withDuration: 0.15) {
            bar.alpha = 0
        } completion: { _ in
            bar.isHidden = true
        }
    }

    /// Returns the URL when the block's spans collapse to a single
    /// external link — the plain text is exactly the URL and the
    /// `.link` style points to it. `nil` for anything else (mixed
    /// text + URL, `pinkha://` internal links, multiple links).
    /// Used by `textViewDidChange` to flip the block to a `.embed`
    /// card without an explicit user gesture.
    private func soleURLForAutoEmbed(in spans: [InlineTextFfi]) -> String? {
        // Reject `pinkha://` links — those are internal mentions and
        // should stay inline.
        let plain = spans.map(\.content).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty,
              !plain.hasPrefix("pinkha://"),
              let parsed = URL(string: plain),
              parsed.scheme == "http" || parsed.scheme == "https",
              parsed.host?.isEmpty == false
        else { return nil }
        // Also require the URL to round-trip via `NSDataDetector` —
        // it's stricter than `URL(string:)` and matches our
        // `linkifyWordEndingAtCursor` heuristic, so the user only
        // ever sees an auto-embed when they typed something we
        // already styled as a hyperlink.
        let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(plain.startIndex..<plain.endIndex, in: plain)
        guard let match = detector?.firstMatch(in: plain, range: range),
              match.range == range
        else { return nil }
        return parsed.absoluteString
    }

    /// Returns a URL if the candidate string is a real link.
    /// `NSDataDetector` is the same engine UIKit uses for Live Text
    /// and Mail's autolinking, so the heuristic matches user
    /// expectations for what "looks like a URL." A bare `foo.com`
    /// (no scheme) gets `https://` prepended when accepted.
    private func resolveURL(_ candidate: String) -> URL? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue,
        )
        let range = NSRange(location: 0, length: (trimmed as NSString).length)
        guard let match = detector?.firstMatch(in: trimmed, range: range),
              match.range == range,
              let url = match.url
        else { return nil }
        return url
    }

    // ── Save ──────────────────────────────────────────────────────────────────

    func save(_ spans: [InlineTextFfi]) {
        // When `onSaveSpans` is wired (block editors), prefer the ID-safe
        // callback path: the VM looks up the block by ID, updates its `spans`,
        // and the observation re-renders the editor. Writing
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
