import UIKit

// ── Bouton menu avec hooks présentation/fermeture ────────────────────────────

/// Sous-classe `UIButton` qui intercepte `contextMenuInteraction(_:willEndFor:)` sur
/// l'`UIContextMenuInteraction` interne installée par `showsMenuAsPrimaryAction = true`.
/// Permet de savoir quand le menu se ferme — y compris lors du dismiss par tap hors du menu —
/// cas où `textViewDidChangeSelection` ne se déclenche pas.
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

// ── UITextView auto-extensible ────────────────────────────────────────────────

/// Sous-classe `UITextView` qui se redimensionne verticalement et intercepte les raccourcis
/// clavier matériel pour Shift+Enter, les toggles gras/italique/souligné, et la navigation inter-blocs.
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

    /// Gère les touches flèches pour la navigation inter-blocs. Retourne les presses non traitées.
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

    /// Retourne `true` si le curseur est sur la première ligne visuelle de la vue texte.
    private func isOnFirstLine() -> Bool {
        guard !text.isEmpty, let pos = selectedTextRange?.start else { return true }
        let caret = caretRect(for: pos)
        let first = caretRect(for: beginningOfDocument)
        return abs(caret.minY - first.minY) < 2
    }

    /// Retourne `true` si le curseur est sur la dernière ligne visuelle de la vue texte.
    private func isOnLastLine() -> Bool {
        guard !text.isEmpty, let pos = selectedTextRange?.start else { return true }
        let caret = caretRect(for: pos)
        let last  = caretRect(for: endOfDocument)
        return abs(caret.minY - last.minY) < 2
    }
}
