import UIKit

// ── Extension Toolbar ─────────────────────────────────────────────────────────

extension RichTextEditorCoordinator {

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

        // Bouton unique B/I/U/S — menu déroulant comme le highlighter.
        // Ouverture : `UIDeferredMenuElement.uncached` cache la pill.
        // Fermeture : `onMenuWillEnd` la restaure (couvre le dismiss par tap hors du menu).
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

        // Bouton highlighter placé juste à droite du bouton style (sans séparateur).
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
        // Reset défensif : `insertText` programmatique peut bypasser `shouldChangeTextIn`,
        // laissant `shiftEnterTyped = true`. La prochaine Entrée clavier serait alors
        // traitée comme saut de ligne au lieu de diviser le bloc.
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

    /// Met à jour les visuels des boutons undo/redo via l'état live de
    /// `canUndoProvider`/`canRedoProvider`. Appelé depuis `updateUIView`,
    /// `textViewDidChange` et `textViewDidChangeSelection`.
    /// Met en cache le dernier état connu pour éviter de recréer `UIImage` à chaque frappe.
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
