import SwiftUI
import PinkhaFFI
import PinkhaCore
import PinkhaDesignSystem
import PinkhaRichText
import PinkhaComposer

// ── Toolbar and overlay buttons ───────────────────────────────────────────────

public extension LeafView {

    /// Resolves the accent the editor should paint with. A per-doc
    /// `accentColor` overrides the app-wide setting; `nil` (the default
    /// for any pre-existing doc) inherits from `AppSettings`. Computed
    /// fresh on every body re-eval so flipping the per-doc choice
    /// repaints the toolbar / chrome immediately.
    var effectiveAccentColor: Color {
        if let name = vm.accentColor {
            return Color(uiColor: uiColorFromName(name))
        }
        return settings.accentColor
    }

    /// Resolved Books-style theme — per-doc override wins, otherwise
    /// the global setting. Drives the editor's background colour,
    /// foreground colour, optional bold base font, and a forced
    /// colorScheme for system widgets to match the palette.
    var effectiveTheme: AppSettings.Theme {
        if let raw = vm.theme,
           let theme = AppSettings.Theme(rawValue: raw) {
            return theme
        }
        return settings.theme
    }

    /// Resolves the active dark-variant flag from the 5-way appearance
    /// enum stored on the leaf (`Light / Dark / Match Device / Match
    /// Surroundings / Match Settings`). `Match Settings` reads the
    /// app-wide `settings.themeDarkVariant` ; `Match Device` and the
    /// (placeholder) `Match Surroundings` read the device trait.
    /// Read by every site that needs to know whether the theme's
    /// dark palette should apply.
    /// Device's true userInterfaceStyle, ignoring window overrides —
    /// what "Match Device" resolves to. iOS Settings → Display &
    /// Brightness.
    var deviceIsDark: Bool {
        UITraitCollection.deviceUserInterfaceStyle == .dark
    }

    /// Resolved app-wide appearance — what "Match Settings" resolves
    /// to. Reads `AppSettings.appearance` (system / light / dark) and
    /// falls back to the device for `.system`. This is the override
    /// that drives the app's chrome (window `overrideUserInterfaceStyle`),
    /// NOT the separate `themeDarkVariant` toggle (which is per-leaf
    /// theme palette state, not an appearance preference).
    var appWideIsDark: Bool {
        switch settings.appearance {
        case .light:  return false
        case .dark:   return true
        case .system: return deviceIsDark
        }
    }

    var effectiveThemeDarkVariant: Bool {
        let mode = ReaderAppearance.parse(vm.readerSettings.themeAppearance)
        return mode.effectiveDark(
            systemIsDark: deviceIsDark,
            settingsIsDark: appWideIsDark
        )
    }

    /// Keyboard appearance derived from the effective theme — light
    /// keyboard for light backgrounds, dark for dark, `.default` for
    /// the system-matching `.original` theme. Plumbed onto every
    /// editor's UITextView so the keyboard window (which sits in its
    /// own UIWindow and ignores our app-window override) stays in
    /// sync with the doc surface.
    var effectiveKeyboardAppearance: UIKeyboardAppearance {
        switch effectiveTheme.effectiveColorScheme(darkVariant: effectiveThemeDarkVariant) {
        case .light: return .light
        case .dark:  return .dark
        default:     return .default
        }
    }

    @ToolbarContentBuilder
    var documentToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            // The principal slot fades in once the user scrolls past
            // the inline title (~60 pt). Shows the current doc title
            // alone for root pages, OR a Notion-style breadcrumb
            // (Parent › Child › This) for nested sub-pages — tap on
            // any segment dismisses back to that ancestor.
            titleBubble
                // The opacity / offset animation went away with the
                // conditional creation above — the bubble now slides
                // in from the principal slot via SwiftUI's default
                // transition when the `if` flips on. Keeping the
                // `.animation` modifier on the toolbar item caused
                // an extra body re-eval per scroll frame for nothing.
                .transition(.opacity.combined(with: .offset(y: 8)))
        }
        if editMode == .active && !selectedBlocks.isEmpty && !vm.locked {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { deleteSelectedBlocks() } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete selected blocks")
            }
            // iOS 26 : isolates the destructive contextual action into its
            // own glass capsule so it doesn't visually fuse with the doc
            // chrome (lock + edit + overflow). Matches Mail / Photos.
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            LockToolbarButton(
                locked: vm.locked,
                accent: effectiveAccentColor
            ) {
                Haptic.toggle()
                let newLocked = !vm.locked
                withAnimation(.easeInOut(duration: 0.15)) {
                    // Apply UI side-effects of locking *before* the save
                    // round-trip — they only depend on `newLocked` and would
                    // race the observation re-render otherwise.
                    if newLocked {
                        editMode = .inactive; selectedBlocks.removeAll()
                        focusTitle = false; showingBlockPicker = false
                        vm.stopNavigationRepeat()
                    }
                    // VM is the source of truth for the lock flag now —
                    // persists to SQLite via the FFI + registers undo.
                    vm.saveLocked(newLocked)
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Haptic.toggle()
                withAnimation {
                    editMode = editMode == .active ? .inactive : .active
                    if editMode != .active { selectedBlocks.removeAll() }
                }
            } label: {
                Image(systemName: editMode == .active ? "checkmark" : "arrow.up.arrow.down")
            }
            // Neutral chrome — override the TabView's accent that
            // propagates through the env.
            .tint(.primary)
            .disabled(vm.locked)
        }
        // PRO-61 : UIKit bridge. SwiftUI Menu's popover gets dimmed by
        // iOS 26 when a `.glassEffect()` overlay is visible below, and
        // SwiftUI exposes no way to track Menu open/close (so we can't
        // hide the overlays at the right moment from SwiftUI alone).
        // `LeafOverflowMenuButton` wraps a `UIButton` with a UIKit
        // `UIMenu` and uses `UIDeferredMenuElement.uncached` as a
        // lifecycle spy — its provider closure fires on every
        // presentation, giving us a reliable `onMenuOpen` signal.
        // Combined with `.menuActionTriggered` for dismiss-on-select
        // and an 8 s fallback timer for tap-outside dismissal, we
        // flip `isOverflowMenuOpen` precisely enough to hide the
        // FAB + UndoRedoPill while the popover is on screen — making
        // the menu render bright.
        ToolbarItem(placement: .primaryAction) {
            let isPinned = (store.allLeaves
                .first(where: { $0.id == vm.leafId })?.pinnedAt ?? "")
                .isEmpty == false
            LeafOverflowMenuButton(
                isLocked: vm.locked,
                isPinned: isPinned,
                accentColorName: vm.accentColor,
                textDirection: vm.textDirection,
                theme: vm.theme,
                settingsThemeLabel: settings.theme.labelString,
                availableThemes: AppSettings.Theme.allCases.map { ($0.rawValue, $0.labelString) },
                accentPalette: BlockColorOption.palette,
                onToggleLock: { vm.saveLocked(!vm.locked) },
                onTogglePin: {
                    store.setLeafPinned(leafId: vm.leafId, pinned: !isPinned)
                },
                onSetAccent: { vm.saveAccentColor($0) },
                onSetTextDirection: { vm.saveTextDirection($0) },
                onSetTheme: { vm.saveTheme($0) },
                onShowPublishDate: { showingPublishDateSheet = true },
                onShowAttachToBook: { showingAttachToBookSheet = true },
                onToggleReaderMode: { readerMode.toggle() },
                onShowReaderSettings: { showingReaderSettingsSheet = true },
                onShare: { sourceView in
                    presentShareSheet(sourceView: sourceView)
                },
                onMenuOpen: { isOverflowMenuOpen = true },
                onMenuClose: { isOverflowMenuOpen = false }
            )
            .frame(width: 44, height: 44)
            .accessibilityLabel("Leaf options")
        }
    }

    /// Generic SwiftUI `Binding` that reads / writes a single field
    /// of `vm.readerSettings` and persists through `saveReaderSettings`
    /// on every set. Used by `ReaderThemeCustomizationSheet` so each
    /// slider toggle flows directly to Rust.
    func readerSettingsBinding<Value>(_ keyPath: WritableKeyPath<LeafReaderSettings, Value>) -> Binding<Value> {
        Binding(
            get: { vm.readerSettings[keyPath: keyPath] },
            set: { newValue in
                var s = vm.readerSettings
                s[keyPath: keyPath] = newValue
                vm.saveReaderSettings(s)
            }
        )
    }

    /// True when the leaf's `readerSettings` exactly matches the
    /// active theme's factory defaults — drives the Reset button's
    /// disabled state in the customize sheet (Apple Books pattern).
    /// Compared field-by-field : font_scale + font_family (Original
    /// = nil) + bold + line/letter/word spacing + margin + justify
    /// + custom-layout flag. Ignores `themeDarkVariant` since it's
    /// a separate axis (sun/moon toggle, not part of typography).
    var isAtThemeFactoryDefaults: Bool {
        let s = vm.readerSettings
        let t = effectiveTheme
        return s.fontScale == 1.0
            && s.fontFamily == nil
            && s.bold == t.defaultBold
            && s.lineSpacing == t.defaultLineSpacing
            && s.letterSpacing == 0.0
            && s.wordSpacing == 0.0
            && s.marginScale == 0.0
            && s.justify == t.defaultJustify
            && s.customLayoutEnabled == t.defaultCustomLayoutEnabled
    }

    /// Snippet of the leaf's actual content surfaced in the
    /// customize-theme sheet's live preview. Mirrors Apple Books'
    /// behaviour of rendering the current book's prose in the
    /// preview pane rather than canned sample text. We surface the
    /// title (if any) + the first few text-bearing blocks.
    func leafPreviewSnippet() -> String {
        var pieces: [String] = []
        let trimmedTitle = vm.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { pieces.append(trimmedTitle) }
        for block in vm.blocks.prefix(8) {
            let line = block.content.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { pieces.append(line) }
            if pieces.joined(separator: " ").count > 280 { break }
        }
        return pieces.joined(separator: "\n\n")
    }

    /// Presents a `UIActivityViewController` rooted in the overflow
    /// button. The UIKit menu can't host a SwiftUI `ShareLink`, so
    /// the Share action surfaces the system share sheet imperatively.
    func presentShareSheet(sourceView: UIView) {
        guard let url = URL(string: "pinkha://leaf/\(vm.leafId)") else { return }
        let title = vm.title.isEmpty ? String(localized: "Untitled") : vm.title
        let avc = UIActivityViewController(activityItems: [url, title], applicationActivities: nil)
        avc.popoverPresentationController?.sourceView = sourceView
        avc.popoverPresentationController?.sourceRect = sourceView.bounds
        // Find the top-most presented controller so the share sheet
        // stacks above any open sheet (sub-leaf editor, etc.).
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let root = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
        var presenter = root
        while let next = presenter?.presentedViewController { presenter = next }
        presenter?.present(avc, animated: true)
    }

    /// Whether `vm.leafId` is somewhere below `targetId` in the
    /// `parentLeafId` tree (used by the popToDoc handler to defensively
    /// clear pushedLeafId on every doc between the target and current).
    /// No depth cap — `seen` is the cycle guard, so legitimate trees
    /// can nest arbitrarily deep. Walk stops only on a cycle or root.
    func isDescendant(of targetId: String) -> Bool {
        var currentId = vm.leafId
        var seen: Set<String> = [currentId]
        while let meta = docMetaById[currentId],
              let parentId = meta.parentLeafId,
              !seen.contains(parentId) {
            if parentId == targetId { return true }
            seen.insert(parentId)
            currentId = parentId
        }
        return false
    }

    /// Walks up the `parentLeafId` chain via `store.leaves` to build
    /// the breadcrumb. Root → … → this doc. Returns `[self]` for root
    /// pages (single segment, rendered as a plain title bubble).
    private var breadcrumbPath: [LeafMetaFfi] {
        // `docMetaById` is loaded on appear from `listLeaves()`
        // (includes sub-pages, unlike `store.leaves` which is
        // root-only). Until it's populated, no breadcrumb is shown.
        guard var node = docMetaById[vm.leafId] else { return [] }
        var path: [LeafMetaFfi] = [node]
        var seen: Set<String> = [node.id]
        while let parentId = node.parentLeafId,
              let parent = docMetaById[parentId],
              !seen.contains(parent.id) {
            path.insert(parent, at: 0)
            seen.insert(parent.id)
            node = parent
        }
        return path
    }

    @ViewBuilder
    private var titleBubble: some View {
        // Skip the whole bubble — including the iOS 26 `.glassEffect`
        // backdrop blur, which is composited even when the parent's
        // opacity is 0 — until the user actually scrolls past the
        // inline title. The previous `.opacity(titleInNavBar ? 1 : 0)`
        // hid it visually but kept the expensive blur layer alive on
        // every scroll frame. Now the entire view tree only exists
        // when it has something to show.
        if !titleInNavBar {
            EmptyView()
        } else {
            titleBubbleContent
        }
    }

    @ViewBuilder
    private var titleBubbleContent: some View {
        let path = breadcrumbPath
        if path.count > 1 {
            // Breadcrumb : tap any ancestor segment to dismiss back to
            // it. Truncates each segment so the bubble fits on screen
            // even with long titles.
            HStack(spacing: 4) {
                ForEach(Array(path.enumerated()), id: \.element.id) { idx, meta in
                    if idx > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    let isLast = idx == path.count - 1
                    let titleText = Text(meta.titlePlain.isEmpty
                                          ? "Untitled" : meta.titlePlain)
                        .font(.subheadline.weight(isLast ? .semibold : .regular))
                        .foregroundStyle(isLast ? .primary : .secondary)
                    if isLast {
                        // Current doc — non-tappable, just shows
                        // "you are here" in the chain.
                        titleText
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        // Ancestor — tap pops the NavStack to it.
                        Button {
                            NotificationCenter.default.post(
                                name: Composer.popToDocNotification,
                                object: nil,
                                userInfo: ["leafId": meta.id])
                        } label: {
                            titleText
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 36)
            .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
        } else {
            // Root page : plain title bubble (no breadcrumb chevrons).
            Button {
                // Placeholder — keeps the bubble tappable until the
                // long-press / switcher feature is wired up.
            } label: {
                Group {
                    if vm.title.isEmpty {
                        Text("Untitled")
                    } else {
                        Text(vm.title)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
            }
            .buttonStyle(.plain)
            .contentShape(Capsule(style: .continuous))
            .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
        }
    }

    @ViewBuilder
    var overlayButtons: some View {
        // Reader mode hides every chrome surface — the floating block
        // FAB and the undo/redo pill are interactive controls, so they
        // belong in the "hidden" set. Re-enter via the multi-finger
        // long-press or the root-level eyeglasses.slash button.
        //
        // **`!isOverflowMenuOpen` guard (PRO-61 workaround)** : iOS 26
        // dims menu popovers whenever a `.glassEffect()` overlay is
        // visible underneath them — the "glass-on-glass" stacking the
        // system avoids defensively. Wrapping the overlays in a
        // `GlassEffectContainer` didn't fix it (verified by bisect on
        // 2026-06-26). The cleanest workaround is to hide the FAB +
        // UndoRedoPill while the overflow popover is on screen, which
        // is exactly when the dim would happen. The overlays restore
        // immediately on dismissal — short-lived flicker is invisible.
        if !readerMode.isActive && !isOverflowMenuOpen {
            if !vm.locked && editMode == .inactive && !keyboardVisible {
                ExpandingBlockFAB(
                    isExpanded: $blockFABExpanded,
                    onSelect: { type in vm.addBlock(type: type, afterId: vm.activeBlockId) },
                    onOpenFullPicker: { showingBlockPicker = true }
                )
                .padding(.trailing, 24)
                .padding(.bottom, accessoryPlacement == .inline ? -70 : 8)
                .transition(.scale.combined(with: .opacity))
            }
            // UndoRedoPill steps aside while the right FAB is morphed
            // into its expanded capsule, so the two floating chunks
            // don't visually fight for space.
            if !vm.locked && editMode == .inactive && !keyboardVisible && !blockFABExpanded {
                UndoRedoPill(canUndo: vm.canUndo, canRedo: vm.canRedo,
                             onUndo: { vm.undo() }, onRedo: { vm.redo() })
                    .padding(.leading, 24)
                    .padding(.bottom, accessoryPlacement == .inline ? -70 : 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }
}
