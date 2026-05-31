import UIKit

// ── Extension Selection & Toolbar state ──────────────────────────────────────

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
            // pendingColor takes priority: typingAttributes is reset by
            // textViewDidBeginEditing after the menu closes, but color mode remains active.
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

    /// Returns the selection to use for a toolbar action: the current selection if non-empty,
    /// otherwise the last remembered non-empty selection (captured before the menu opened).
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

    /// Returns `true` if `check` is satisfied for every attribute run in `range`.
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
        // Fallback on font symbolic traits: UIKit removes custom attributes from typingAttributes
        // after insertion, but the bold font descriptor remains reliable.
        // Compared against baseFont so a heading (already bold by design) is not marked
        // as user-applied bold.
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

    // Utility method to update the paste button (called from updateToolbar and pasteboardChanged).
    func updatePasteButton() {
        setSymbolActive(btnPaste, active: UIPasteboard.general.hasStrings, name: "doc.on.clipboard")
    }
}
