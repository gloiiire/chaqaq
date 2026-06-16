import SwiftUI
import PinkhaFFI
import PinkhaRichText

// ── Auto-focus shared extension ───────────────────────────────────────────────

public extension View {
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

/// Callback bundle passed from the leaf view to each block row.
public struct BlockCallbacks {
    public var onSave: () -> Void
    public var onSaveSpans: ([InlineTextFfi]) -> Void
    public var onDelete: () -> Void
    public var onNewBlock: ([InlineTextFfi]) -> Void
    public var onMerge: (([InlineTextFfi]) -> Void)? = nil
    public var onNavigatePrevious: (() -> Void)? = nil
    public var onNavigateNext: (() -> Void)? = nil
    public var onStopNavigationRepeat: (() -> Void)? = nil
    public var onLongPressSelection: (() -> Void)? = nil
    public var onFocus: (() -> Void)? = nil
    // Atomic mutations with undo: routed via the VM (toggleBlockDone, etc.)
    // so the inverse is registered on the undo stack.
    public var onToggleDone: (() -> Void)? = nil
    public var onChangeIcon: ((String) -> Void)? = nil
    public var onConvertContent: ((BlockContentFfi) -> Void)? = nil
    // Undo/redo exposed in the keyboard pill. Live closures — the Coordinator
    // calls them in textViewDidChange/textViewDidChangeSelection + updateUIView,
    // covering typing, undo, redo and selection changes.
    public var onUndo: (() -> Void)? = nil
    public var onRedo: (() -> Void)? = nil
    public var canUndoProvider: (() -> Bool)? = nil
    public var canRedoProvider: (() -> Bool)? = nil
    /// Wired to FFI `indent_block` / `outdent_block` via the VM. `nil` keeps
    /// the toolbar button visible but inert — the FFI call will still throw
    /// `InvalidOperation` if the block can't move (first in level / at root).
    public var onIndent: (() -> Void)? = nil
    public var onOutdent: (() -> Void)? = nil
    /// Block-level colour pipeline: provider reads the current value so the
    /// toolbar's ¶ button can highlight the active colour, and the closure
    /// applies a new one (nil = clear back to default) via the VM.
    public var onSetBlockColor: ((String?) -> Void)? = nil
    /// Block-level *background* colour (Craft highlight). Same shape
    /// as `onSetBlockColor` — the closure persists via the VM, the
    /// row reads the current value off the block and paints the band.
    public var onSetBlockBackgroundColor: ((String?) -> Void)? = nil
    /// Resolved writing direction for this block (per-block override
    /// or leaf default, fallback to system locale). `"ltr"` or
    /// `"rtl"` ; `nil` leaves it to the OS.
    public var effectiveTextDirection: String? = nil
    /// Setter for the per-block writing direction. `nil` = inherit
    /// from the leaf. Routes through the VM → FFI.
    public var onSetBlockTextDirection: ((String?) -> Void)? = nil
    /// Returns the list of leaves available for `@`-mentions —
    /// shown as an action sheet when the user types `@` at the
    /// start of a word. `nil` disables the feature.
    public var onMentionLookup: (() -> [MentionCandidate])? = nil
    /// Deep-clones the block (FFI side regenerates every UUID) and
    /// inserts the copy right after the original. The VM focuses the
    /// new block once the reload settles.
    public var onDuplicate: (() -> Void)? = nil
    /// Accent color the row should paint its accented affordances with
    /// (todo checkmark, etc.). Resolved at the LeafView level so a
    /// per-doc accent overrides the global setting; the default falls
    /// back to the SwiftUI env tint when no LeafView is in the
    /// chain (preview / other contexts).
    public var accentColor: Color = .accentColor
    /// Resolved Books-style theme foreground colour. `nil` keeps the
    /// system `.label` fallback. Plumbed all the way down to the
    /// `RichTextEditor` so every span without a more specific colour
    /// inherits the right body-text colour for the active theme.
    public var themeForegroundColor: Color? = nil
    /// Forced keyboard appearance for the per-doc theme. UIKit's
    /// keyboard window doesn't pick up the doc-window
    /// `overrideUserInterfaceStyle`, so we set this directly on the
    /// textView.
    public var keyboardAppearance: UIKeyboardAppearance = .default
    /// Called when an inline `pinkha://doc/{uuid}` link is tapped — the
    /// parent navigates to that leaf. Set by `LeafView` and read by
    /// `RichTextEditor`.
    public var onOpenInternalDoc: ((String) -> Void)? = nil
    /// Resolves a child-page block to a display title + optional icon. Used
    /// by `ChildPageRowView` to surface the embedded page's name without
    /// loading the entire child leaf. Returns `nil` for a deleted or
    /// missing child page.
    public var resolveChildPage: ((String) -> (title: String, icon: String?)?)? = nil
}

// ── Shared text editor for all blocks ────────────────────────────────────────
// Single wiring of RichTextEditor + auto-focus + focus change detection. Each RowView
// only provides the placeholder, font, decorations and block-specific options.

/// Wraps `RichTextEditor` with auto-focus logic and focus change tracking.
public struct BlockTextEditor: View {
    @Binding var block: EditableBlock
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    public let placeholder: String
    public let baseFont: UIFont
    public var extraAttrs: [NSAttributedString.Key: Any]? = nil
    public var convertible: Bool = true
    public let cb: BlockCallbacks
    @State private var focused = false
    @State private var cursorAt: Int?

    public var body: some View {
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
            accentColor: UIColor(cb.accentColor),
            onSetBlockColor: cb.onSetBlockColor,
            blockBackgroundColor: block.backgroundColor,
            onSetBlockBackgroundColor: cb.onSetBlockBackgroundColor,
            textDirection: cb.effectiveTextDirection,
            themeForegroundColor: cb.themeForegroundColor.map(UIColor.init),
            keyboardAppearance: cb.keyboardAppearance,
            onMentionLookup: cb.onMentionLookup,
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

/// Walks the block's spans looking for a URL we can promote to a
/// `.embed` card : either an inline `.link(...)` style, or — when no
/// link style is present — the block's plain text if it parses as a
/// single URL. Returns `nil` when there's nothing embeddable.
func extractEmbedURL(from block: EditableBlock) -> String? {
    for span in block.spans {
        for style in span.styles {
            if case .link(let url) = style, !url.isEmpty {
                return url
            }
        }
    }
    let plain = block.spans.map(\.content).joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !plain.isEmpty,
          let detector = try? NSDataDetector(
              types: NSTextCheckingResult.CheckingType.link.rawValue),
          let match = detector.firstMatch(
              in: plain,
              range: NSRange(plain.startIndex..<plain.endIndex, in: plain)),
          match.range.location == 0,
          match.range.length == (plain as NSString).length,
          let url = match.url
    else { return nil }
    return url.absoluteString
}

// ── Block row dispatcher ──────────────────────────────────────────────────────

/// Routes each block to its dedicated row view based on the content type.
public struct BlockRowView: View {
    @Binding var block: EditableBlock
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    public let cb: BlockCallbacks

    public var body: some View {
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
                ChildPageRowView(childLeafId: id, cb: cb)
            case .embed(let url):
                EmbedRowView(url: url, cb: cb)
            default:
                EmptyView()
            }
        }
        // Block-level background highlight band — Craft / Notion
        // style. Opacity 0.15 keeps it readable in both schemes and
        // avoids fighting with the per-span / per-block foreground.
        // Negative horizontal padding extends the band slightly past
        // the row content so the highlight reads as "the whole line"
        // rather than "just the text".
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(block.backgroundColor.map {
                    Color(uiColor: uiColorFromName($0)).opacity(0.15)
                } ?? .clear)
                .padding(.horizontal, -8)
        )
        .contextMenu {
            // "Convert to embed" — appears when the block contains
            // exactly one URL (inline link or plain-text URL). Swaps
            // the text block for an `.embed` block that renders as
            // a rich preview card.
            if let urlForEmbed = extractEmbedURL(from: block) {
                Button {
                    cb.onConvertContent?(.embed(url: urlForEmbed))
                } label: {
                    Label {
                        Text("Convert to embed")
                    } icon: {
                        Image(uiImage: Self.neutralIcon("rectangle.on.rectangle"))
                    }
                }
            }
            if let onDuplicate = cb.onDuplicate {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onDuplicate()
                } label: {
                    Label {
                        Text("Duplicate")
                    } icon: {
                        Image(uiImage: Self.neutralIcon("plus.square.on.square"))
                    }
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
                        Label {
                            Text(type.displayName)
                        } icon: {
                            Image(uiImage: Self.neutralIcon(type.icone))
                        }
                    }
                }
            } label: {
                Label {
                    Text("Change to")
                } icon: {
                    Image(uiImage: Self.neutralIcon("arrow.triangle.2.circlepath"))
                }
            }
            // "Color" — paints the whole block in one of the palette
            // colors. Inline color styles on individual spans always
            // win, so this only repaints text that has no per-span
            // color of its own (matches the Rust render contract).
            // Rendered as a `Picker(.inline)` rather than plain
            // Buttons — that's the only Menu construct iOS 26
            // actually colours the icons inside (verified pattern
            // from `LibraryView` sort menu).
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
                            Image(uiImage: Self.neutralIcon("circle.dashed"))
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
                    Label {
                        Text("Color")
                    } icon: {
                        Image(uiImage: Self.neutralIcon("paintpalette"))
                    }
                }
            }
            // "Text direction" — per-block override of the leaf's
            // default writing direction. `Default` clears so the block
            // inherits; LTR / RTL force a specific direction.
            if let onSetDir = cb.onSetBlockTextDirection {
                Menu {
                    Button {
                        onSetDir(nil)
                    } label: {
                        Label {
                            Text("Default")
                        } icon: {
                            Image(uiImage: Self.neutralIcon("circle.dashed"))
                        }
                    }
                    Button {
                        onSetDir("ltr")
                    } label: {
                        Label {
                            Text("Left to right")
                        } icon: {
                            Image(uiImage: Self.neutralIcon("text.alignleft"))
                        }
                    }
                    Button {
                        onSetDir("rtl")
                    } label: {
                        Label {
                            Text("Right to left")
                        } icon: {
                            Image(uiImage: Self.neutralIcon("text.alignright"))
                        }
                    }
                } label: {
                    Label {
                        Text("Text direction")
                    } icon: {
                        Image(uiImage: Self.neutralIcon("text.justify"))
                    }
                }
            }
            // "Background" — soft tinted band painted behind the
            // whole block (Craft / Notion highlight). Mirror of the
            // Color picker right above, persisted via a separate FFI.
            if let onSetBg = cb.onSetBlockBackgroundColor {
                Menu {
                    Button {
                        onSetBg(nil)
                    } label: {
                        Label {
                            Text("Default")
                        } icon: {
                            Image(uiImage: Self.neutralIcon("circle.dashed"))
                        }
                    }
                    ForEach(BlockColorOption.palette) { option in
                        Button {
                            onSetBg(option.name)
                        } label: {
                            Label {
                                Text(option.displayName)
                            } icon: {
                                Image(uiImage: option.swatchImage)
                            }
                        }
                    }
                } label: {
                    Label {
                        Text("Background")
                    } icon: {
                        Image(uiImage: Self.neutralIcon("highlighter"))
                    }
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

    /// SF Symbol rendered as a neutral `.label`-colored UIImage so the
    /// menu can't re-tint it to the env accent (per-doc accent
    /// otherwise paints every Duplicate / Change-to / Color trigger
    /// in the doc's color, which fights the "menu chrome stays
    /// neutral" rule we follow elsewhere). Same `.alwaysOriginal`
    /// trick as `trashIcon` and the color swatches. Cached so the
    /// menu doesn't reallocate UIImages on every open.
    private static var neutralIconCache: [String: UIImage] = [:]
    static func neutralIcon(_ name: String) -> UIImage {
        if let cached = neutralIconCache[name] { return cached }
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        let base = UIImage(systemName: name, withConfiguration: config) ?? UIImage()
        let tinted = base.withTintColor(.label, renderingMode: .alwaysOriginal)
        neutralIconCache[name] = tinted
        return tinted
    }
}

// ── Palette options for the block-color context menu ──────────────────────────
//
// The Rust side stores a color *name* (e.g. `"red"`); the rendering side
// already maps names to `UIColor` via `uiColorFromName(_:)`. This struct
// surfaces the same palette to SwiftUI as a stable, identifiable list
// the menu can iterate over.

public struct BlockColorOption: Identifiable, @unchecked Sendable {
    public let id: String
    public let name: String
    public let displayName: LocalizedStringKey
    public let uiColor: UIColor

    /// Pre-rendered filled circle with the color baked into pixels.
    /// Cached at first access — the menu re-renders on every open and
    /// reallocating 10 UIImages each time would show up in the
    /// AttributeGraph trace.
    public var swatchImage: UIImage {
        BlockColorOption.swatchCache[id] ?? Self.buildSwatch(for: self)
    }

    nonisolated(unsafe) private static var swatchCache: [String: UIImage] = [:]

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
    public let cb: BlockCallbacks

    public var body: some View {
        BlockTextEditor(block: $block, autoFocusId: $autoFocusId, autoFocusOffset: $autoFocusOffset,
                       placeholder: String(localized: "Text…"), baseFont: .preferredFont(forTextStyle: .body), cb: cb)
    }
}

// ── Heading ───────────────────────────────────────────────────────────────────

private struct HeadingRowView: View {
    @Binding var block: EditableBlock
    public let level: Int
    @Binding var autoFocusId: String?
    @Binding var autoFocusOffset: Int?
    public let cb: BlockCallbacks

    private var uiFont: UIFont {
        switch level {
        case 1:  return .systemFont(ofSize: 26, weight: .bold)
        case 2:  return .systemFont(ofSize: 22, weight: .semibold)
        default: return .systemFont(ofSize: 18, weight: .semibold)
        }
    }

    public var body: some View {
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
    public let cb: BlockCallbacks

    public var body: some View {
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
    public let cb: BlockCallbacks

    public var body: some View {
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
    public let language: String
    public let text: String
    public let cb: BlockCallbacks

    @State private var editedText: String

    public init(block: Binding<EditableBlock>, language: String, text: String, cb: BlockCallbacks) {
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

    public var body: some View {
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

/// Inline reference to a child pinkha leaf — mirrors Notion's child_page
/// block. Tapping the row pushes the child leaf onto the surrounding
/// `NavigationStack` via the parent's `onOpenInternalDoc` callback.
public struct ChildPageRowView: View {
    public let childLeafId: String
    public let cb: BlockCallbacks

    @State private var resolved: (title: String, icon: String?)? = nil

    public var body: some View {
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
        .highPriorityGesture(TapGesture().onEnded { cb.onOpenInternalDoc?(childLeafId) })
        .onAppear { resolved = cb.resolveChildPage?(childLeafId) }
    }
}
