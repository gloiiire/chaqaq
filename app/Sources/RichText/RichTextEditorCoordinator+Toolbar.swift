import UIKit

// ── Extension Toolbar ─────────────────────────────────────────────────────────

extension RichTextEditorCoordinator {

    func makeToolbar() -> UIView {
        let pillH: CGFloat  = 64
        let margeV: CGFloat = 8
        let margeH: CGFloat = 4
        let largeur = tv?.window?.screen.bounds.width ?? 390
        let totalH  = pillH + margeV * 2

        let container = OverflowingAccessoryContainer(
            frame: CGRect(x: 0, y: 0, width: largeur, height: totalH))
        container.backgroundColor = .clear
        container.autoresizingMask = [.flexibleWidth]
        // The `@`-mention bar lives ABOVE the visible container bounds
        // (it's a subview pushed up by a negative y). Letting it draw
        // outside removes the cross-window dance we were doing
        // before — the bar always rides with the input accessory.
        // The custom subclass also makes touches up there land on the
        // bar instead of falling through to the textView underneath.
        container.clipsToBounds = false

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

        // Single B/I/U/S button — dropdown menu like the highlighter.
        // Opening: `UIDeferredMenuElement.uncached` hides the pill.
        // Closing: `onMenuWillEnd` restores it (covers dismiss by tapping outside the menu).
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

        // Highlighter button placed just to the right of the style button (no separator).
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

        // Block color (¶) — applies a colour to the whole block. Inline
        // `.color(...)` on individual spans still wins at render time.
        let bBlockColor = MenuButton(type: .custom)
        bBlockColor.showsMenuAsPrimaryAction = true
        bBlockColor.menu = blockColorMenu(current: parent.blockColor)
        bBlockColor.onMenuWillEnd = { [weak self] in
            self?.menuPresentingUntil = nil
            self?.setToolbarHidden(false)
        }
        bBlockColor.setImage(UIImage(systemName: "paragraphsign", withConfiguration: cfgH)?
            .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal), for: .normal)
        addButton(bBlockColor); btnBlockColor = bBlockColor

        // Block background colour — Craft / Notion highlight band
        // painted behind the whole block. Mirror of the ¶ button just
        // above; lives next to it because both are "block-level"
        // colour controls (foreground vs background).
        let bBlockBg = MenuButton(type: .custom)
        bBlockBg.showsMenuAsPrimaryAction = true
        bBlockBg.menu = blockBackgroundColorMenu(current: parent.blockBackgroundColor)
        bBlockBg.onMenuWillEnd = { [weak self] in
            self?.menuPresentingUntil = nil
            self?.setToolbarHidden(false)
        }
        bBlockBg.setImage(UIImage(systemName: "rectangle.fill", withConfiguration: cfgH)?
            .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal), for: .normal)
        addButton(bBlockBg); btnBlockBg = bBlockBg

        // Link button — applies an inline URL to the current selection
        // (or inserts a hyperlink at the cursor when nothing is selected
        // by inserting a placeholder span). Long-press on an already-
        // linked range exposes Edit / Remove via the contextMenu in
        // BlockRows; this button is the discovery entry.
        separator()
        addButton(symbolButton("link", action: #selector(toolbarLink)))

        separator()
        let bUndo = symbolButton("arrow.uturn.backward", action: #selector(toolbarUndo))
        addButton(bUndo); btnUndo = bUndo
        let bRedo = symbolButton("arrow.uturn.forward", action: #selector(toolbarRedo))
        addButton(bRedo); btnRedo = bRedo
        updateUndoRedoButtons()

        // Indent / outdent — nests / unnests the current block, calling the
        // FFI `indent_block` / `outdent_block` via closures owned by the
        // DocumentViewModel (which knows the block identity).
        separator()
        addButton(symbolButton("decrease.quotelevel", action: #selector(toolbarOutdent)))
        addButton(symbolButton("increase.quotelevel", action: #selector(toolbarIndent)))

        separator()
        addButton(symbolButton("return", action: #selector(toolbarLineBreak)))
        separator()
        addButton(symbolButton("keyboard.chevron.compact.down", action: #selector(dismissKeyboard)))

        scroll.contentSize = CGSize(width: x + 12, height: pillH)
        return container
    }

    @objc func captureSelectionBeforeToolbar() {
        // Fires on every keyboard-pill button's `.touchDown` — perfect
        // hook for the haptic since it covers every UIKit-backed
        // toolbar control (paste / style menu / highlighter / link /
        // undo / redo / indent / outdent / return / dismiss) without
        // touching each handler individually.
        Haptic.tap()
        toolbarActionInProgress = true
        guard let tv else { return }
        if tv.selectedRange.length == 0 { clearRememberedSelection() }
        rememberSelection(tv.selectedRange, length: tv.attributedText.length)
    }

    func setToolbarHidden(_ hidden: Bool) {
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
        // Defensive reset: programmatic `insertText` can bypass `shouldChangeTextIn`,
        // leaving `shiftEnterTyped = true`. The next keyboard Enter would then be
        // treated as a line break instead of splitting the block.
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

    @objc func toolbarIndent() {
        toolbarActionInProgress = false
        parent.onIndent?()
    }

    @objc func toolbarOutdent() {
        toolbarActionInProgress = false
        parent.onOutdent?()
    }

    /// Toolbar link button : reads the current selection, presents an
    /// alert asking for the URL (prefilled with the existing one if
    /// the selection already has a `.link` attribute), then applies
    /// it via `applyStyle(.link)`. With no selection, also asks for
    /// the label text so we know what to insert.
    @objc func toolbarLink() {
        guard let tv else { return }
        captureSelectionBeforeToolbar()
        let attr = tv.attributedText ?? NSAttributedString()
        let range = selectionForToolbar(currentSelection: tv.selectedRange,
                                        length: attr.length)
        let existing: String = {
            guard range.length > 0,
                  let url = attr.attribute(.link,
                                            at: range.location,
                                            effectiveRange: nil) as? URL
            else { return "" }
            return url.absoluteString
        }()
        if range.length > 0 {
            promptForLink(prefill: existing, hasLabel: true) { [weak self] url in
                self?.applyStyle(.link(url ?? ""))
                _ = self?.tv?.becomeFirstResponder()
            }
        } else {
            // No selection : ask for both label + URL, insert as a new
            // linked span at the cursor. Reuses `applyStyle(.link)` by
            // first inserting the label, selecting it, then applying.
            promptForLink(prefill: "", hasLabel: false) { [weak self] url in
                guard let self, let tv = self.tv,
                      let url, !url.isEmpty,
                      let resolved = URL(string: url)
                else { _ = self?.tv?.becomeFirstResponder(); return }
                let label = url
                let m = NSMutableAttributedString(attributedString: tv.attributedText)
                let insert = NSMutableAttributedString(string: label,
                    attributes: [
                        .font: parent.baseFont,
                        .foregroundColor: UIColor.label,
                        .link: resolved,
                    ])
                m.insert(insert, at: tv.selectedRange.location)
                tv.textStorage.beginEditing()
                tv.textStorage.setAttributedString(m)
                tv.textStorage.endEditing()
                let newCursor = tv.selectedRange.location + (label as NSString).length
                tv.selectedRange = NSRange(location: newCursor, length: 0)
                save(attributedToSpans(tv.attributedText, police: parent.baseFont))
                updateToolbar()
                _ = tv.becomeFirstResponder()
            }
        }
    }

    /// Pops an alert with a single (URL) or two (label + URL) text
    /// fields. `completion` receives the URL the user typed, or `nil`
    /// if they cancelled — `""` means they tapped Remove on an
    /// existing link.
    private func promptForLink(
        prefill: String,
        hasLabel: Bool,
        completion: @escaping (String?) -> Void,
    ) {
        guard let host = tv?.window?.rootViewController else {
            completion(nil)
            return
        }
        let alert = UIAlertController(
            title: String(localized: "Link"),
            message: nil,
            preferredStyle: .alert,
        )
        alert.addTextField {
            $0.placeholder = String(localized: "URL")
            $0.text = prefill
            $0.keyboardType = .URL
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(
            title: String(localized: "Cancel"),
            style: .cancel,
        ) { _ in completion(nil) })
        // "Remove" only makes sense when an existing link is present.
        if !prefill.isEmpty {
            alert.addAction(UIAlertAction(
                title: String(localized: "Remove"),
                style: .destructive,
            ) { _ in completion("") })
        }
        alert.addAction(UIAlertAction(
            title: hasLabel
                ? String(localized: "Apply")
                : String(localized: "Insert"),
            style: .default,
        ) { _ in
            let url = alert.textFields?.first?.text ?? ""
            completion(url)
        })
        host.present(alert, animated: true)
    }

    /// Updates the undo/redo button visuals via the live state from
    /// `canUndoProvider`/`canRedoProvider`. Called from `updateUIView`,
    /// `textViewDidChange` and `textViewDidChangeSelection`.
    /// Caches the last known state to avoid recreating `UIImage` on every keystroke.
    func updateUndoRedoButtons() {
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

    func applyEnabled(_ btn: UIButton?, enabled: Bool, symbol: String) {
        guard let btn else { return }
        let cfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        let color: UIColor = enabled ? .secondaryLabel : .tertiaryLabel
        btn.setImage(UIImage(systemName: symbol, withConfiguration: cfg)?
            .withTintColor(color, renderingMode: .alwaysOriginal), for: .normal)
        btn.isEnabled = enabled
        btn.alpha = enabled ? 1.0 : 0.5
    }
}

/// Input-accessory container that lets touches land on subviews that
/// draw beyond its own bounds — needed for the `@`-mention bar which
/// sits visually *above* the container so the keyboard pill stays in
/// place. UIKit's default `point(inside:with:)` rejects out-of-bounds
/// hits, so a tap on the bar would otherwise fall through to the
/// editor underneath.
final class OverflowingAccessoryContainer: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        for sub in subviews where !sub.isHidden && sub.alpha > 0 {
            if sub.frame.contains(point) { return true }
        }
        return false
    }
}
