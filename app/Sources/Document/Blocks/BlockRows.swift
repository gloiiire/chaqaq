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
    /// Block-level colour pipeline: provider reads the current value so the
    /// toolbar's ¶ button can highlight the active colour, and the closure
    /// applies a new one (nil = clear back to default) via the VM.
    var onSetBlockColor: ((String?) -> Void)? = nil
    /// Deep-clones the block (FFI side regenerates every UUID) and
    /// inserts the copy right after the original. The VM focuses the
    /// new block once the reload settles.
    var onDuplicate: (() -> Void)? = nil
    /// Called when an inline `pinkha://doc/{uuid}` link is tapped — the
    /// parent navigates to that document. Set by `DocumentView` and read by
    /// `RichTextEditor`.
    var onOpenInternalDoc: ((String) -> Void)? = nil
    /// Resolves a child-page block to a display title + optional icon. Used
    /// by `ChildPageRowView` to surface the embedded page's name without
    /// loading the entire child document. Returns `nil` for a deleted or
    /// missing child page.
    var resolveChildPage: ((String) -> (title: String, icon: String?)?)? = nil
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
            onOutdent: cb.onOutdent,
            blockColor: block.color,
            onSetBlockColor: cb.onSetBlockColor,
            onOpenInternalDoc: cb.onOpenInternalDoc)
        .autoFocusIfNeeded(blockId: block.id, autoFocusId: $autoFocusId,
                              autoFocusOffset: $autoFocusOffset, cursorAt: $cursorAt, focused: $focused)
        .onChange(of: focused) { _, f in if f { cb.onFocus?() } }
    }
}

// ── Block content factory ─────────────────────────────────────────────────────

/// Builds a `BlockContentFfi` for the given `NewBlockType`, carrying
/// over the supplied spans (inline text + styles) so a "Change to"
/// conversion keeps what the user already wrote. `.divider` ignores
/// the spans by definition.
func blockContent(for type: NewBlockType,
                  preserving spans: [InlineTextFfi]) -> BlockContentFfi {
    switch type {
    case .text:    return .text(spans)
    case .title1:  return .heading(level: 1, text: spans)
    case .title2:  return .heading(level: 2, text: spans)
    case .title3:  return .heading(level: 3, text: spans)
    case .quote:   return .quote(icon: "", text: spans)
    case .callout: return .quote(icon: "💡", text: spans)
    case .todo:    return .todo(done: false, text: spans)
    case .divider: return .divider
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
                // `Divider()` orients itself based on its parent stack
                // — the surrounding HStack would render it as a vertical
                // line. Use an explicit horizontal hairline matching the
                // iOS native separator colour + standard 1 pt thickness.
                Rectangle()
                    .fill(Color(uiColor: .separator))
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            case .bulletedListItem:
                BulletedListItemRowView(block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset, cb: cb)
            case .numberedListItem:
                NumberedListItemRowView(block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset, cb: cb)
            case .code(let language, let text):
                CodeBlockEditorView(block: $block, language: language, text: text, cb: cb)
            case .page(let id):
                ChildPageRowView(childDocId: id, cb: cb)
            default:
                EmptyView()
            }
        }
        .contextMenu {
            if let onDuplicate = cb.onDuplicate {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onDuplicate()
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
            }
            // "Change to" — convert the existing block to another
            // type while preserving its inline content (text spans).
            // Routes through the same FFI as markdown shortcuts.
            Menu {
                ForEach(NewBlockType.allCases) { type in
                    Button {
                        cb.onConvertContent?(
                            blockContent(for: type, preserving: block.spans)
                        )
                    } label: {
                        Label(type.displayName, systemImage: type.icone)
                    }
                }
            } label: {
                Label("Change to", systemImage: "arrow.triangle.2.circlepath")
            }
            // "Color" — paints the whole block in one of the palette
            // colors. Inline color styles on individual spans always
            // win, so this only repaints text that has no per-span
            // color of its own (matches the Rust render contract).
            // Rendered as a `Picker(.inline)` rather than plain
            // Buttons — that's the only Menu construct iOS 26
            // actually colours the icons inside (verified pattern
            // from `NotesHomeView` sort menu).
            if let onSetColor = cb.onSetBlockColor {
                Menu {
                    // Plain Buttons + UIImage circles : iOS 26 strips
                    // `foregroundStyle` from icon Images inside both
                    // Menus and inline Pickers (only the *selected*
                    // row of an inline Picker keeps the tint). A
                    // pre-rendered UIImage with the color burned into
                    // the pixels survives the strip — the renderer
                    // treats it as opaque content, not a tintable
                    // template.
                    Button {
                        onSetColor(nil)
                    } label: {
                        Label {
                            Text("Default")
                        } icon: {
                            Image(systemName: "circle.dashed")
                        }
                    }
                    ForEach(BlockColorOption.palette) { option in
                        Button {
                            onSetColor(option.name)
                        } label: {
                            Label {
                                Text(option.displayName)
                            } icon: {
                                Image(uiImage: option.swatchImage)
                            }
                        }
                    }
                } label: {
                    Label("Color", systemImage: "paintpalette")
                }
            }
            Divider()
            // Destructive role colours the text red on its own.
            // The icon, however, gets re-tinted to the menu's default
            // even with `role: .destructive` in iOS 26 — same root
            // cause as the colour swatches above. A pre-tinted UIImage
            // with `.alwaysOriginal` rendering survives the strip.
            Button(role: .destructive, action: cb.onDelete) {
                Label {
                    Text("Delete block")
                } icon: {
                    Image(uiImage: Self.trashIcon)
                }
            }
        }
    }

    /// Red trash glyph baked into a UIImage so the menu renderer treats
    /// it as opaque content (rather than a template it re-tints). Built
    /// once and reused — `UIImage(systemName:)` returns a configurable
    /// template, the `.applyingSymbolConfiguration` + `.withTintColor`
    /// + `.alwaysOriginal` chain renders it into a concrete red bitmap.
    private static let trashIcon: UIImage = {
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        let base = UIImage(systemName: "trash", withConfiguration: config)
            ?? UIImage()
        return base.withTintColor(.systemRed, renderingMode: .alwaysOriginal)
    }()
}

// ── Palette options for the block-color context menu ──────────────────────────
//
// The Rust side stores a color *name* (e.g. `"red"`); the rendering side
// already maps names to `UIColor` via `uiColorFromName(_:)`. This struct
// surfaces the same palette to SwiftUI as a stable, identifiable list
// the menu can iterate over.

private struct BlockColorOption: Identifiable {
    let id: String
    let name: String
    let displayName: LocalizedStringKey
    let uiColor: UIColor

    /// Pre-rendered filled circle with the color baked into pixels.
    /// Cached at first access — the menu re-renders on every open and
    /// reallocating 10 UIImages each time would show up in the
    /// AttributeGraph trace.
    var swatchImage: UIImage {
        BlockColorOption.swatchCache[id] ?? Self.buildSwatch(for: self)
    }

    private static var swatchCache: [String: UIImage] = [:]

    private static func buildSwatch(for option: BlockColorOption) -> UIImage {
        let size: CGFloat = 18
        let img = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
            .image { _ in
                option.uiColor.setFill()
                UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: size, height: size)).fill()
            }
            // `.alwaysOriginal` flags the image as opaque content the
            // menu rendering pipeline must not re-tint to its accent.
            .withRenderingMode(.alwaysOriginal)
        swatchCache[option.id] = img
        return img
    }

    static let palette: [BlockColorOption] = [
        .init(id: "red",    name: "red",    displayName: "Red",    uiColor: .systemRed),
        .init(id: "pink",   name: "pink",   displayName: "Pink",   uiColor: .systemPink),
        .init(id: "orange", name: "orange", displayName: "Orange", uiColor: .systemOrange),
        .init(id: "yellow", name: "yellow", displayName: "Yellow", uiColor: .systemYellow),
        .init(id: "green",  name: "green",  displayName: "Green",  uiColor: .systemGreen),
        .init(id: "cyan",   name: "cyan",   displayName: "Cyan",   uiColor: .systemCyan),
        .init(id: "blue",   name: "blue",   displayName: "Blue",   uiColor: .systemBlue),
        .init(id: "purple", name: "purple", displayName: "Purple", uiColor: .systemPurple),
        .init(id: "brown",  name: "brown",  displayName: "Brown",  uiColor: .systemBrown),
        .init(id: "gray",   name: "gray",   displayName: "Gray",   uiColor: .systemGray),
    ]
}

// ── Text ──────────────────────────────────────────────────────────────────────

private struct TextRowView: View {
    @Binding var block: EditableBlock
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    let cb: BlockCallbacks

    var body: some View {
        BlockTextEditor(block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset,
                       placeholder: String(localized: "Text…"), baseFont: .preferredFont(forTextStyle: .body), cb: cb)
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

// ── Child page row ────────────────────────────────────────────────────────────

/// Inline reference to a child pinkha document — mirrors Notion's child_page
/// block. Tapping the row pushes the child document onto the surrounding
/// `NavigationStack` via the parent's `onOpenInternalDoc` callback.
struct ChildPageRowView: View {
    let childDocId: String
    let cb: BlockCallbacks

    @State private var resolved: (title: String, icon: String?)? = nil

    var body: some View {
        HStack(spacing: 12) {
            // Icon slot sized like the home-view row to anchor the eye —
            // emoji when the child has one, generic doc glyph otherwise.
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.secondary.opacity(0.10))
                    .frame(width: 30, height: 30)
                if let icon = resolved?.icon, !icon.isEmpty {
                    Text(icon).font(.title3)
                } else {
                    Image(systemName: "doc.text")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            Group {
                if let r = resolved, !r.title.isEmpty { Text(r.title) }
                else { Text("Untitled") }
            }
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // Card surface — same quaternary-fill recipe as the inset-grouped
        // rows in the home view. Replaces the previous underlined-link
        // look with a self-contained block the eye reads as a target.
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // High-priority gesture wins over any inherited .disabled or
        // gesture recogniser higher up the view tree (the locked doc's
        // .disabled wrapper, the row's selection tap, etc.) — page-
        // reference blocks are pure navigation targets and should fire
        // their tap regardless of editing state.
        .highPriorityGesture(TapGesture().onEnded { cb.onOpenInternalDoc?(childDocId) })
        .onAppear { resolved = cb.resolveChildPage?(childDocId) }
    }
}
