import UIKit

// ── Menu button with present/close hooks ──────────────────────────────────────

/// `UIButton` subclass that intercepts `contextMenuInteraction(_:willEndFor:)` on
/// the internal `UIContextMenuInteraction` installed by `showsMenuAsPrimaryAction = true`.
/// Lets us know when the menu closes — including when dismissed by tapping outside —
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

// ── Auto-expanding UITextView ─────────────────────────────────────────────────

/// `UITextView` subclass that resizes vertically and intercepts hardware keyboard shortcuts
/// for Shift+Enter, bold/italic/underline toggles, and inter-block navigation.
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
        // Target is iOS 26, so the iOS 15+ availability guard around
        // `wantsPriorityOverSystemBehavior` is dead code — set it directly.
        cmd.wantsPriorityOverSystemBehavior = true
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

    /// Handles arrow keys for inter-block navigation. Returns unhandled presses.
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

    /// Returns `true` if the cursor is on the first visual line of the text view.
    private func isOnFirstLine() -> Bool {
        guard !text.isEmpty, let pos = selectedTextRange?.start else { return true }
        let caret = caretRect(for: pos)
        let first = caretRect(for: beginningOfDocument)
        return abs(caret.minY - first.minY) < 2
    }

    /// Returns `true` if the cursor is on the last visual line of the text view.
    private func isOnLastLine() -> Bool {
        guard !text.isEmpty, let pos = selectedTextRange?.start else { return true }
        let caret = caretRect(for: pos)
        let last  = caretRect(for: endOfDocument)
        return abs(caret.minY - last.minY) < 2
    }
}
