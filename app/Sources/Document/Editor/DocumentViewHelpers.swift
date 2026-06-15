import SwiftUI
import PinkhaRichText

// ── Tappable empty state ──────────────────────────────────────────────────────

/// Placeholder shown when the document has no blocks yet. A tap creates the first block.
struct EmptyEditorState: View {
    let onBegin: () -> Void
    @State private var focused = false

    var body: some View {
        RichTextEditor(
            spans: .constant([]),
            isFocused: $focused,
            placeholder: String(localized: "Start writing…"),
            onSave: nil,
            onNewBlock: nil,
            onDeleteBloc: nil,
            onConvert: nil
        )
        .onChange(of: focused) { _, isFocused in
            if isFocused { onBegin() }
        }
    }
}

// ── Add block button ──────────────────────────────────────────────────────────

/// List footer button that opens the block picker sheet.
struct AddBlockButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                Text("New block")
            }
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }
}

// ── Undo / Redo ───────────────────────────────────────────────────────────────
// A single glass capsule background for both icons — same as the lock/reorder pill
// in the nav bar: one glass capsule, each icon independently tappable.

/// Glass capsule pill with undo and redo buttons. Shown at the bottom-left when the keyboard is hidden.
struct UndoRedoPill: View {
    let canUndo: Bool
    let canRedo: Bool
    let onUndo: () -> Void
    let onRedo: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            iconButton(icon: "arrow.uturn.backward", enabled: canUndo, action: onUndo)
            iconButton(icon: "arrow.uturn.forward",  enabled: canRedo, action: onRedo)
        }
        .glassEffect(.regular.interactive(), in: .capsule)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: canUndo)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: canRedo)
    }

    private func iconButton(icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.45))
                .frame(width: 54, height: 54)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// ── Block type picker sheet ───────────────────────────────────────────────────

/// Sheet listing all available block types for insertion.
struct BlockPickerSheet: View {
    let onSelect: (NewBlockType) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(NewBlockType.allCases) { type in
                Button {
                    onSelect(type)
                    dismiss()
                } label: {
                    Label(type.displayName, systemImage: type.icone)
                        .foregroundStyle(.primary)
                }
            }
            .navigationTitle("Add a block")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .tint(.primary)
                        .accessibilityLabel("Cancel")
                }
            }
        }
        .presentationDetents([.medium])
    }
}
