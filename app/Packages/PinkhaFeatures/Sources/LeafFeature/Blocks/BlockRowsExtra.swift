import SwiftUI
import PinkhaCore

// ── Quote ─────────────────────────────────────────────────────────────────────

public struct QuoteRowView: View {
    @Binding var block: EditableBlock
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let cb: BlockCallbacks
    @Environment(\.readerTheme) private var theme
    @Environment(\.readerFontScale) private var fontScale
    @Environment(\.readerTypography) private var typography

    public var body: some View {
        let baseSize = UIFont.preferredFont(forTextStyle: .body).pointSize * fontScale
        // Build an italic variant by routing through the user's
        // custom-or-theme font resolver, then adding the italic
        // symbolic trait. Falls back to italic system if neither
        // family has an italic face.
        let italic: UIFont = {
            let base = typography.resolvedFont(theme: theme, size: baseSize)
            let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic)
                ?? base.fontDescriptor
            return UIFont(descriptor: descriptor, size: baseSize)
        }()
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 3)
                .padding(.vertical, 6)
            BlockTextEditor(
                block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset,
                placeholder: "Quote…",
                baseFont: italic,
                extraAttrs: typography.attributedAttributes(baseFontSize: baseSize),
                cb: cb)
            .padding(.leading, 14)
        }
        .padding(.vertical, 4)
    }
}

// ── Callout ───────────────────────────────────────────────────────────────────

public struct CalloutRowView: View {
    @Binding var block: EditableBlock
    let icon: String
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let cb: BlockCallbacks
    @State private var emojiPickerOpen = false
    @State private var recentEmojis = loadRecentEmojis()
    @Environment(\.readerTheme) private var theme
    @Environment(\.readerFontScale) private var fontScale
    @Environment(\.readerTypography) private var typography

    public var body: some View {
        // First-text-baseline alignment so the emoji sits right next
        // to the text's first line regardless of how many lines the
        // user types — icon stays "fixed" near the top, text grows
        // downwards on its own.
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                emojiPickerOpen = true
            } label: {
                Text(icon)
                    .font(.system(size: 24))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Reserve a fixed width so the text wrapping doesn't
            // jitter when the emoji glyph changes width (emojis vary
            // ~20-36 pt).
            .frame(width: 32, alignment: .center)

            CalloutText(block: $block, autoFocusId: $autoFocusId,
                        autoFocusOffset: $autoFocusOffset, cb: cb)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        )
        .padding(.vertical, 8)
        .sheet(isPresented: $emojiPickerOpen) {
            EmojiPickerSheet(selection: icon, recents: recentEmojis) { emoji in
                recentEmojis = saveRecentEmoji(emoji)
                // Route via the VM so the change is registered on the undo stack.
                cb.onChangeIcon?(emoji)
            }
        }
    }
}

/// Extracted out of `CalloutRowView.body` so the `BlockTextEditor` call
/// can keep its own `@Environment` reads (font scale + theme + typo)
/// without falling foul of SwiftUI's `@ViewBuilder` restrictions on
/// `do { }` blocks.
private struct CalloutText: View {
    @Binding var block: EditableBlock
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let cb: BlockCallbacks
    @Environment(\.readerTheme) private var theme
    @Environment(\.readerFontScale) private var fontScale
    @Environment(\.readerTypography) private var typography

    var body: some View {
        let size = UIFont.preferredFont(forTextStyle: .body).pointSize * fontScale
        BlockTextEditor(block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset,
                       placeholder: "Callout…",
                       baseFont: typography.resolvedFont(theme: theme, size: size),
                       extraAttrs: typography.attributedAttributes(baseFontSize: size),
                       cb: cb)
    }
}

// ── Todo ──────────────────────────────────────────────────────────────────────

public struct TodoRowView: View {
    @Binding var block: EditableBlock
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let cb: BlockCallbacks
    @Environment(AppSettings.self) private var settings
    @Environment(\.readerTheme) private var theme
    @Environment(\.readerFontScale) private var fontScale
    @Environment(\.readerTypography) private var typography

    /// Extra text attributes applied when the item is checked (strikethrough + secondary color).
    private var checkedAttrs: [NSAttributedString.Key: Any]? {
        block.done ? [
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .foregroundColor: UIColor.secondaryLabel
        ] : nil
    }

    private var baseSize: CGFloat {
        UIFont.preferredFont(forTextStyle: .body).pointSize * fontScale
    }

    /// Merges the strikethrough-when-done attrs with the typography
    /// overrides so a checked Todo still gets the paragraph styling
    /// and kerning from Personnaliser.
    private var mergedAttrs: [NSAttributedString.Key: Any]? {
        var merged = typography.attributedAttributes(baseFontSize: baseSize)
        if let extra = checkedAttrs {
            for (k, v) in extra { merged[k] = v }
        }
        return merged.isEmpty ? nil : merged
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                cb.onToggleDone?()
            } label: {
                Image(systemName: block.done ? "checkmark.square.fill" : "square")
                    .font(.body)
                    // Use the BlockCallbacks-supplied accent so a
                    // per-doc override (LeafView.effectiveAccentColor)
                    // wins over `settings.accentColor`. The callback's
                    // default is `Color.accentColor` for non-doc
                    // previews. `.foregroundStyle(.tint)` was failing
                    // to propagate through here in earlier tests, so
                    // we plumb an explicit value instead.
                    .foregroundStyle(block.done ? cb.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            BlockTextEditor(block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset,
                           placeholder: "To do…",
                           baseFont: typography.resolvedFont(theme: theme, size: baseSize),
                           extraAttrs: mergedAttrs,
                           convertible: false, cb: cb)
        }
        .padding(.vertical, 2)
    }
}
