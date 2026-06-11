import UIKit

// ── Extension Style ───────────────────────────────────────────────────────────

extension RichTextEditorCoordinator {

    @objc func toggleBold()       { applyStyle(.bold) }
    @objc func toggleItalic()     { applyStyle(.italic) }
    @objc func toggleUnderline()  { applyStyle(.underline) }
    @objc func toggleStrike()     { applyStyle(.strikethrough) }

    func applyColor(_ name: String) { applyStyle(.color(name)) }

    func clearColor() {
        defer { toolbarActionInProgress = false }
        guard let tv, let attr = tv.attributedText else { return }
        // Falling back to UIColor.label hardcoded would erase the block-level
        // colour applied via the ¶ palette. The fallback foreground must be
        // the current `blockColor` when one is set, so removing an inline
        // colour reveals the block colour underneath — matches the
        // domain rule "inline color overrides block color".
        let fallback: UIColor = parent.blockColor.map(uiColorFromName) ?? .label
        let range = selectionForToolbar(currentSelection: tv.selectedRange, length: attr.length)
        guard range.length > 0 else {
            var attrs = tv.typingAttributes
            attrs.removeValue(forKey: .pinkhaColor)
            attrs[.foregroundColor] = fallback
            tv.typingAttributes = attrs
            pendingColor = nil
            updateToolbar()
            clearRememberedSelection()
            _ = tv.becomeFirstResponder()
            return
        }
        let m = NSMutableAttributedString(attributedString: attr)
        m.removeAttribute(.pinkhaColor, range: range)
        m.addAttribute(.foregroundColor, value: fallback, range: range)
        tv.textStorage.beginEditing()
        tv.textStorage.setAttributedString(m)
        tv.textStorage.endEditing()
        tv.selectedRange = range
        rememberSelection(range, length: m.length)
        save(attributedToSpans(tv.attributedText, police: parent.baseFont))
        updateToolbar()
    }

    func applyStyle(_ style: InlineStyleFfi) {
        defer { toolbarActionInProgress = false }
        guard let tv, let attr = tv.attributedText else { return }
        let range = selectionForToolbar(currentSelection: tv.selectedRange, length: attr.length)

        guard range.length > 0 else {
            applyStyleTyping(tv: tv, style: style)
            return
        }

        let m = NSMutableAttributedString(attributedString: attr)

        switch style {
        case .bold:
            let allBold = entireRange(in: attr, range: range, check: attrsContainBold)
            attr.enumerateAttribute(.font, in: range) { _, r, _ in
                let italic = attrsContainItalic(in: attr, position: r.location)
                m.addAttribute(.font, value: fontWithTraits(parent.baseFont, bold: !allBold, italic: italic), range: r)
                if italic { m.addAttribute(.pinkhaObliqueness, value: 0.2, range: r) }
                else       { m.removeAttribute(.pinkhaObliqueness, range: r) }
            }
            if !allBold { m.addAttribute(.pinkhaBold,    value: true, range: range) }
            else         { m.removeAttribute(.pinkhaBold,              range: range) }

        case .italic:
            let allItalic = entireRange(in: attr, range: range, check: attrsContainItalic)
            attr.enumerateAttribute(.font, in: range) { _, r, _ in
                let bold = attrsContainBold(in: attr, position: r.location)
                m.addAttribute(.font, value: fontWithTraits(parent.baseFont, bold: bold, italic: !allItalic), range: r)
            }
            if !allItalic {
                m.addAttribute(.pinkhaItalic, value: true, range: range)
                m.addAttribute(.pinkhaObliqueness, value: 0.2, range: range)
            } else {
                m.removeAttribute(.pinkhaItalic, range: range)
                m.removeAttribute(.pinkhaObliqueness, range: range)
            }

        case .underline:
            let already = attr.attribute(.underlineStyle, at: range.location, effectiveRange: nil) != nil
            if already { m.removeAttribute(.underlineStyle, range: range) }
            else    { m.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }

        case .strikethrough:
            let already = attr.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) != nil
            if already { m.removeAttribute(.strikethroughStyle, range: range) }
            else    { m.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }

        case .color(let nom):
            let current = attr.attribute(.pinkhaColor, at: range.location, effectiveRange: nil) as? String
            if current == nom {
                m.removeAttribute(.foregroundColor, range: range)
                m.removeAttribute(.pinkhaColor,     range: range)
                m.addAttribute(.foregroundColor, value: UIColor.label, range: range)
            } else {
                m.addAttribute(.foregroundColor, value: uiColorFromName(nom), range: range)
                m.addAttribute(.pinkhaColor,     value: nom,                  range: range)
            }
        case .link(let url):
            // Empty URL = remove the link from the selection — same
            // shape as `clearColor` for inline colours. Valid URL =
            // attach the `.link` attribute so `attributedToSpans`
            // round-trips it back to `InlineStyle::Link(String)`.
            if url.isEmpty {
                m.removeAttribute(.link, range: range)
            } else if let resolved = URL(string: url) {
                m.addAttribute(.link, value: resolved, range: range)
            }
        default: break
        }

        tv.textStorage.beginEditing()
        tv.textStorage.setAttributedString(m)
        tv.textStorage.endEditing()
        tv.selectedRange  = range
        rememberSelection(range, length: m.length)
        save(attributedToSpans(tv.attributedText, police: parent.baseFont))
        updateToolbar()
        // The color menu (showsMenuAsPrimaryAction) resigns first responder;
        // restore it to keep the keyboard and selection visible.
        _ = tv.becomeFirstResponder()
    }

    func applyStyleTyping(tv: UITextView, style: InlineStyleFfi) {
        var attrs = tv.typingAttributes
        switch style {
        case .bold:
            let bold   = attrsContainBold(attrs)
            let italic = attrsContainItalic(attrs)
            attrs[.font] = fontWithTraits(parent.baseFont, bold: !bold, italic: italic)
            if !bold { attrs[.pinkhaBold] = true } else { attrs.removeValue(forKey: .pinkhaBold) }
            if italic { attrs[.pinkhaObliqueness] = 0.2 }
            else      { attrs.removeValue(forKey: .pinkhaObliqueness) }
        case .italic:
            let bold   = attrsContainBold(attrs)
            let italic = attrsContainItalic(attrs)
            attrs[.font] = fontWithTraits(parent.baseFont, bold: bold, italic: !italic)
            if !italic {
                attrs[.pinkhaItalic] = true
                attrs[.pinkhaObliqueness] = 0.2
            } else {
                attrs.removeValue(forKey: .pinkhaItalic)
                attrs.removeValue(forKey: .pinkhaObliqueness)
            }
        case .underline:
            if attrs[.underlineStyle] != nil { attrs.removeValue(forKey: .underlineStyle) }
            else { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        case .strikethrough:
            if attrs[.strikethroughStyle] != nil { attrs.removeValue(forKey: .strikethroughStyle) }
            else { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        case .color(let nom):
            // Source of truth: pendingColor (typingAttributes is reset by
            // textViewDidBeginEditing after the menu closes).
            let currentColor = pendingColor ?? (attrs[.pinkhaColor] as? String)
            if currentColor == nom {
                attrs.removeValue(forKey: .pinkhaColor)
                attrs[.foregroundColor] = UIColor.label
                pendingColor = nil
            } else {
                attrs[.foregroundColor] = uiColorFromName(nom)
                attrs[.pinkhaColor]     = nom
                pendingColor = nom
            }
        default: break
        }
        tv.typingAttributes = attrs
        updateToolbar()
        clearRememberedSelection()
        _ = tv.becomeFirstResponder()
    }
}
