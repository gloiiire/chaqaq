import UIKit

// ── Extension Sélection & Toolbar state ──────────────────────────────────────

extension RichTextEditorCoordinator {

    func updateToolbar() {
        guard let tv else { return }
        let attr = tv.attributedText ?? NSAttributedString()
        let len  = attr.length
        let range = tv.selectedRange

        let bold: Bool; let italic: Bool; let underline: Bool; let strike: Bool; let color: String?
        if range.length > 0, range.location < len {
            let loc = min(range.location, len - 1)
            bold      = entireRange(in: attr, range: range, check: attrsContainBold)
            italic    = entireRange(in: attr, range: range, check: attrsContainItalic)
            underline = attr.attribute(.underlineStyle,     at: loc, effectiveRange: nil) != nil
            strike    = attr.attribute(.strikethroughStyle, at: loc, effectiveRange: nil) != nil
            color     = attr.attribute(.pinkhaColor,        at: loc, effectiveRange: nil) as? String
        } else {
            let attrs = tv.typingAttributes
            bold      = attrsContainBold(attrs)
            italic    = attrsContainItalic(attrs)
            underline = attrs[.underlineStyle]     != nil
            strike    = attrs[.strikethroughStyle]  != nil
            // pendingColor a la priorité : typingAttributes est réinitialisé par
            // textViewDidBeginEditing après la fermeture du menu, mais le mode couleur reste actif.
            color = pendingColor ?? (attrs[.pinkhaColor] as? String)
        }

        updateTextStyleButton(bold: bold, italic: italic, underline: underline, strike: strike)
        updateColorButton(color)
        updatePasteButton()
    }

    func setSymbolActive(_ btn: UIButton?, active: Bool, name: String, size: CGFloat = 22) {
        guard let btn else { return }
        let c: UIColor = active ? (UIColor(named: "Accent") ?? .tintColor) : .secondaryLabel
        let cfg = UIImage.SymbolConfiguration(pointSize: size, weight: .medium)
        btn.setImage(UIImage(systemName: name, withConfiguration: cfg)?
            .withTintColor(c, renderingMode: .alwaysOriginal), for: .normal)
    }

    func rememberSelection(_ range: NSRange, length: Int) {
        let selection = normalizedSelection(range, length: length)
        guard selection.length > 0 else { return }
        selectionGeneration += 1
        lastSelection = selection
    }

    func clearRememberedSelection() {
        selectionGeneration += 1
        lastSelection = NSRange(location: 0, length: 0)
    }

    func cleanRememberedIfStillEmpty(_ textView: UITextView) {
        let generation = selectionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak textView] in
            guard let self, let textView else { return }
            let selection = self.normalizedSelection(textView.selectedRange, length: textView.attributedText.length)
            if self.selectionGeneration == generation && !self.toolbarActionInProgress && selection.length == 0 {
                self.clearRememberedSelection()
            }
        }
    }

    /// Retourne la sélection à utiliser pour une action toolbar : la sélection courante si non vide,
    /// sinon la dernière sélection non vide mémorisée (définie avant l'ouverture du menu).
    func selectionForToolbar(currentSelection: NSRange, length: Int) -> NSRange {
        let current = normalizedSelection(currentSelection, length: length)
        if current.length > 0 { return current }
        let remembered = normalizedSelection(lastSelection, length: length)
        return remembered.length > 0 ? remembered : current
    }

    func normalizedSelection(_ range: NSRange, length: Int) -> NSRange {
        guard range.location != NSNotFound, range.location <= length else {
            return NSRange(location: length, length: 0)
        }
        let end = min(range.location + range.length, length)
        return NSRange(location: range.location, length: max(0, end - range.location))
    }

    /// Retourne `true` si `check` est satisfait pour chaque séquence d'attributs dans `range`.
    func entireRange(
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

    func attrsContainBold(in attr: NSAttributedString, position: Int) -> Bool {
        attrsContainBold(attr.attributes(at: position, effectiveRange: nil))
    }

    func attrsContainItalic(in attr: NSAttributedString, position: Int) -> Bool {
        attrsContainItalic(attr.attributes(at: position, effectiveRange: nil))
    }

    func attrsContainBold(_ attrs: [NSAttributedString.Key: Any]) -> Bool {
        if (attrs[.pinkhaBold] as? Bool) == true { return true }
        // Fallback sur les traits symboliques de la police : UIKit supprime les attributs
        // personnalisés de typingAttributes après l'insertion, mais le descripteur de police gras reste fiable.
        // Comparaison avec baseFont pour ne pas marquer un titre (déjà gras par design)
        // comme gras appliqué par l'utilisateur.
        guard let f = attrs[.font] as? UIFont else { return false }
        return f.fontDescriptor.symbolicTraits.contains(.traitBold)
            && !parent.baseFont.fontDescriptor.symbolicTraits.contains(.traitBold)
    }

    func attrsContainItalic(_ attrs: [NSAttributedString.Key: Any]) -> Bool {
        if (attrs[.pinkhaItalic] as? Bool) == true { return true }
        guard let f = attrs[.font] as? UIFont else { return false }
        return f.fontDescriptor.symbolicTraits.contains(.traitItalic)
            && !parent.baseFont.fontDescriptor.symbolicTraits.contains(.traitItalic)
    }

    // Méthode utilitaire pour mettre à jour le bouton coller (appelée depuis updateToolbar et pasteboardChanged).
    func updatePasteButton() {
        setSymbolActive(btnPaste, active: UIPasteboard.general.hasStrings, name: "doc.on.clipboard")
    }
}
