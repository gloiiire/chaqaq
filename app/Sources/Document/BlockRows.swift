import SwiftUI

// ── Auto-focus shared extension ───────────────────────────────────────────────

extension View {
    /// Déclenche le focus et positionne optionnellement le curseur à `autoFocusOffset` quand
    /// `autoFocusId` correspond à `blockId`. Fonctionne à la fois sur `.onAppear` et sur les
    /// mises à jour `onChange` suivantes (ex. après réinsertion via undo).
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

// ── Callbacks des blocs ─────────────────────────────────────────────────────────
// Regroupe les closures partagées par tous les types de blocs pour éviter de les répéter
// dans chaque RowView et dans BlockRowView.

/// Bundle de callbacks passé depuis la vue document à chaque ligne de bloc.
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
    // Mutations atomiques avec undo : routées via le VM (toggleBlockDone, etc.)
    // pour que l'inverse soit enregistré sur la pile undo.
    var onToggleDone: (() -> Void)? = nil
    var onChangeIcon: ((String) -> Void)? = nil
    var onConvertContent: ((BlockContentFfi) -> Void)? = nil
    // Undo/redo exposés dans la pill clavier. Closures live — le Coordinator
    // les appelle dans textViewDidChange/textViewDidChangeSelection + updateUIView,
    // couvrant frappe, undo, redo et changements de sélection.
    var onUndo: (() -> Void)? = nil
    var onRedo: (() -> Void)? = nil
    var canUndoProvider: (() -> Bool)? = nil
    var canRedoProvider: (() -> Bool)? = nil
}

// ── Éditeur de texte partagé pour tous les blocs ─────────────────────────────
// Câblage unique de RichTextEditor + auto-focus + détection du focus. Chaque RowView
// fournit uniquement le placeholder, la police, les décorations et les options spécifiques au bloc.

/// Wraps `RichTextEditor` avec la logique auto-focus et le suivi des changements de focus.
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
            canRedoProvider: cb.canRedoProvider)
        .autoFocusIfNeeded(blockId: block.id, autoFocusId: $autoFocusId,
                              autoFocusOffset: $autoFocusOffset, cursorAt: $cursorAt, focused: $focused)
        .onChange(of: focused) { _, f in if f { cb.onFocus?() } }
    }
}

// ── Dispatcher de lignes de blocs ─────────────────────────────────────────────

/// Route chaque bloc vers sa vue de ligne dédiée selon le type de contenu.
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
            default:
                EmptyView()
            }
        }
        .contextMenu {
            Button(role: .destructive, action: cb.onDelete) {
                Label("Supprimer le bloc", systemImage: "trash")
            }
        }
    }
}

// ── Texte ──────────────────────────────────────────────────────────────────────

private struct TextRowView: View {
    @Binding var block: EditableBlock
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let cb: BlockCallbacks

    var body: some View {
        BlockTextEditor(block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset,
                       placeholder: "Texte…", baseFont: .preferredFont(forTextStyle: .body), cb: cb)
    }
}

// ── Titre ─────────────────────────────────────────────────────────────────────

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
                       placeholder: "Titre…", baseFont: uiFont, cb: cb)
            .padding(.top, level == 1 ? 16 : 10)
            .padding(.bottom, 4)
    }
}

// QuoteRowView, CalloutRowView et TodoRowView sont dans BlockRowsExtra.swift.
