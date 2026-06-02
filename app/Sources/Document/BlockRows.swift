import SwiftUI

// ── Auto-focus shared extension ───────────────────────────────────────────────

extension View {
    /// Triggers focus and optionally positions the cursor at `autoFocusOffset` when
    /// `autoFocusId` matches `blockId`. Works both on `.onAppear` and on subsequent
    /// `onChange` updates (e.g. after reinsertion via undo).
    func autoFocusIfNeeded(blockId: String,
                              autoFocusId: Binding<String?>,
                              autoFocusOffset: Binding<Int?>,
                              cursorAt: Binding<Int?>,
                              focused: Binding<Bool>) -> some View {
        self
            .onAppear {
                guard autoFocusId.wrappedValue == blockId else { return }
                autoFocusId.wrappedValue = nil
                let off = autoFocusOffset.wrappedValue
                autoFocusOffset.wrappedValue = nil
                DispatchQueue.main.async { cursorAt.wrappedValue = off; focused.wrappedValue = true }
            }
            .onChange(of: autoFocusId.wrappedValue) { _, newId in
                guard newId == blockId else { return }
                autoFocusId.wrappedValue = nil
                let off = autoFocusOffset.wrappedValue
                autoFocusOffset.wrappedValue = nil
                DispatchQueue.main.async { cursorAt.wrappedValue = off; focused.wrappedValue = true }
            }
    }
}

// ── Block callbacks ──────────────────────────────────────────────────────────
// Groups the closures shared by all block types to avoid repeating them
// in every RowView and in BlockRowView.

/// Callback bundle passed from the document view to each block row.
struct BlockCallbacks {
    var onSave: () -> Void
    var onSaveSpans: ([InlineTextFfi]) -> Void
    var onDelete: () -> Void
    var onNewBlock: ([InlineTextFfi]) -> Void
    var onMerge: (([InlineTextFfi]) -> Void)? = nil
    var onNavigatePrevious: (() -> Void)? = nil
    var onNavigateNext: (() -> Void)? = nil
    var onStopNavigationRepeat: (() -> Void)? = nil
    var onLongPressSelection: (() -> Void)? = nil
    var onFocus: (() -> Void)? = nil
    // Atomic mutations with undo: routed via the VM (toggleBlockDone, etc.)
    // so the inverse is registered on the undo stack.
    var onToggleDone: (() -> Void)? = nil
    var onChangeIcon: ((String) -> Void)? = nil
    var onConvertContent: ((BlockContentFfi) -> Void)? = nil
    // Undo/redo exposed in the keyboard pill. Live closures — the Coordinator
    // calls them in textViewDidChange/textViewDidChangeSelection + updateUIView,
    // covering typing, undo, redo and selection changes.
    var onUndo: (() -> Void)? = nil
    var onRedo: (() -> Void)? = nil
    var canUndoProvider: (() -> Bool)? = nil
    var canRedoProvider: (() -> Bool)? = nil
    /// Wired to FFI `indent_block` / `outdent_block` via the VM. `nil` keeps
    /// the toolbar button visible but inert — the FFI call will still throw
    /// `InvalidOperation` if the block can't move (first in level / at root).
    var onIndent: (() -> Void)? = nil
    var onOutdent: (() -> Void)? = nil
}

// ── Shared text editor for all blocks ────────────────────────────────────────
// Single wiring of RichTextEditor + auto-focus + focus change detection. Each RowView
// only provides the placeholder, font, decorations and block-specific options.

/// Wraps `RichTextEditor` with auto-focus logic and focus change tracking.
struct BlockTextEditor: View {
    @Binding var block: EditableBlock
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let placeholder: String
    let baseFont: UIFont
    var extraAttrs: [NSAttributedString.Key: Any]? = nil
    var convertible: Bool = true
    let cb: BlockCallbacks
    @State private var focused = false
    @State private var cursorAt: Int?

    var body: some View {
        RichTextEditor(
            spans: $block.spans,
            isFocused: $focused,
            placeholder: placeholder,
            baseFont: baseFont,
            extraAttrs: extraAttrs,
            focusCursorAt: cursorAt,
            onSave: cb.onSave,
            onSaveSpans: cb.onSaveSpans,
            onNewBlock: cb.onNewBlock,
            onDeleteBloc: cb.onDelete,
            onMergeAvecPrecedent: cb.onMerge,
            onConvert: convertible ? { content in cb.onConvertContent?(content) } : nil,
            onLongPressSelection: cb.onLongPressSelection,
            onNavigatePrevious: cb.onNavigatePrevious,
            onNavigateNext: cb.onNavigateNext,
            onStopNavigationRepeat: cb.onStopNavigationRepeat,
            onUndo: cb.onUndo,
            onRedo: cb.onRedo,
            canUndoProvider: cb.canUndoProvider,
            canRedoProvider: cb.canRedoProvider,
            onIndent: cb.onIndent,
            onOutdent: cb.onOutdent)
        .autoFocusIfNeeded(blockId: block.id, autoFocusId: $autoFocusId,
                              autoFocusOffset: $autoFocusOffset, cursorAt: $cursorAt, focused: $focused)
        .onChange(of: focused) { _, f in if f { cb.onFocus?() } }
    }
}

// ── Block row dispatcher ──────────────────────────────────────────────────────

/// Routes each block to its dedicated row view based on the content type.
struct BlockRowView: View {
    @Binding var block: EditableBlock
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let cb: BlockCallbacks

    var body: some View {
        Group {
            switch block.content {
            case .text:
                TextRowView(block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset, cb: cb)
            case .heading(let level, _):
                HeadingRowView(block: $block, level: level, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset, cb: cb)
            case .quote(let icon, _):
                if icon.isEmpty {
                    QuoteRowView(block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset, cb: cb)
                } else {
                    CalloutRowView(block: $block, icon: icon, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset, cb: cb)
                }
            case .todo:
                TodoRowView(block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset, cb: cb)
            case .divider:
                Divider().padding(.vertical, 12)
            case .bulletedListItem:
                BulletedListItemRowView(block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset, cb: cb)
            case .numberedListItem:
                NumberedListItemRowView(block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset, cb: cb)
            case .code(let language, let text):
                CodeBlockEditorView(block: $block, language: language, text: text, cb: cb)
            default:
                EmptyView()
            }
        }
        .contextMenu {
            Button(role: .destructive, action: cb.onDelete) {
                Label("Delete block", systemImage: "trash")
            }
        }
    }
}

// ── Text ──────────────────────────────────────────────────────────────────────

private struct TextRowView: View {
    @Binding var block: EditableBlock
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let cb: BlockCallbacks

    var body: some View {
        BlockTextEditor(block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset,
                       placeholder: "Text…", baseFont: .preferredFont(forTextStyle: .body), cb: cb)
    }
}

// ── Heading ───────────────────────────────────────────────────────────────────

private struct HeadingRowView: View {
    @Binding var block: EditableBlock
    let level: Int
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let cb: BlockCallbacks

    private var uiFont: UIFont {
        switch level {
        case 1:  return .systemFont(ofSize: 26, weight: .bold)
        case 2:  return .systemFont(ofSize: 22, weight: .semibold)
        default: return .systemFont(ofSize: 18, weight: .semibold)
        }
    }

    var body: some View {
        BlockTextEditor(block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset,
                       placeholder: "Heading…", baseFont: uiFont, cb: cb)
            .padding(.top, level == 1 ? 16 : 10)
            .padding(.bottom, 4)
    }
}

// QuoteRowView, CalloutRowView and TodoRowView are in BlockRowsExtra.swift.

// ── Bulleted list item ─────────────────────────────────────────────────────────

private struct BulletedListItemRowView: View {
    @Binding var block: EditableBlock
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let cb: BlockCallbacks

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("•")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            BlockTextEditor(
                block: $block,
                autoFocusId: $autoFocusId,
                autoFocusOffset: $autoFocusOffset,
                placeholder: "List item…",
                baseFont: .preferredFont(forTextStyle: .body),
                cb: cb)
        }
        .padding(.vertical, 2)
    }
}

// ── Numbered list item ─────────────────────────────────────────────────────────

private struct NumberedListItemRowView: View {
    @Binding var block: EditableBlock
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let cb: BlockCallbacks

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("1.")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            BlockTextEditor(
                block: $block,
                autoFocusId: $autoFocusId,
                autoFocusOffset: $autoFocusOffset,
                placeholder: "List item…",
                baseFont: .preferredFont(forTextStyle: .body),
                cb: cb)
        }
        .padding(.vertical, 2)
    }
}

// ── Code block ────────────────────────────────────────────────────────────────

private struct CodeBlockEditorView: View {
    @Binding var block: EditableBlock
    let language: String
    let text: String
    let cb: BlockCallbacks

    @State private var editedText: String

    init(block: Binding<EditableBlock>, language: String, text: String, cb: BlockCallbacks) {
        self._block = block
        self.language = language
        self.text = text
        self.cb = cb
        self._editedText = State(initialValue: text)
    }

    private func save() {
        block.content = .code(language: language, text: editedText)
        cb.onSave()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !language.isEmpty {
                Text(language)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            TextEditor(text: $editedText)
                .font(.system(.footnote, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )
                .onChange(of: editedText) { _, _ in save() }
        }
        .padding(.vertical, 4)
    }
}
