import SwiftUI

// ── Citation ──────────────────────────────────────────────────────────────────

struct QuoteRowView: View {
    @Binding var block: EditableBlock
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let cb: BlockCallbacks

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 3)
                .padding(.vertical, 6)
            BlockTextEditor(
                block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset,
                placeholder: "Citation…",
                baseFont: .italicSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize),
                cb: cb)
            .padding(.leading, 14)
        }
        .padding(.vertical, 4)
    }
}

// ── Callout ───────────────────────────────────────────────────────────────────

struct CalloutRowView: View {
    @Binding var block: EditableBlock
    let icon: String
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let cb: BlockCallbacks
    @State private var emojiPickerOpen = false
    @State private var recentEmojis = loadRecentEmojis()

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button {
                emojiPickerOpen = true
            } label: {
                Text(icon)
                    .font(.system(size: 28))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)

            BlockTextEditor(block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset,
                           placeholder: "Callout…", baseFont: .preferredFont(forTextStyle: .body), cb: cb)
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
                // Route via le VM pour que le changement soit enregistré sur la pile undo.
                cb.onChangeIcon?(emoji)
            }
        }
    }
}

// ── Todo ──────────────────────────────────────────────────────────────────────

struct TodoRowView: View {
    @Binding var block: EditableBlock
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let cb: BlockCallbacks

    /// Attributs de texte supplémentaires appliqués quand l'item est coché (barré + couleur secondaire).
    private var checkedAttrs: [NSAttributedString.Key: Any]? {
        block.done ? [
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .foregroundColor: UIColor.secondaryLabel
        ] : nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                cb.onToggleDone?()
            } label: {
                Image(systemName: block.done ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(block.done ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)

            BlockTextEditor(block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset,
                           placeholder: "À faire…", baseFont: .preferredFont(forTextStyle: .body),
                           extraAttrs: checkedAttrs, convertible: false, cb: cb)
        }
        .padding(.vertical, 2)
    }
}
