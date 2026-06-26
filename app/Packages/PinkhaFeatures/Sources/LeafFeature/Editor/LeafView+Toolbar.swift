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

    /// Keyboard appearance derived from the effective theme — light
    /// keyboard for light backgrounds, dark for dark, `.default` for
    /// the system-matching `.original` theme. Plumbed onto every
    /// editor's UITextView so the keyboard window (which sits in its
    /// own UIWindow and ignores our app-window override) stays in
    /// sync with the doc surface.
    var effectiveKeyboardAppearance: UIKeyboardAppearance {
        switch effectiveTheme.colorScheme {
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
        // "…" overflow menu — declared LAST so it lands at the far
        // right edge of the toolbar (SwiftUI orders trailing
        // primaryAction items left → right in source order). Collects
        // per-doc settings; first occupant is the accent color picker.
        ToolbarItem(placement: .primaryAction) {
            Menu {
                // Wrap every item in a Group with `.tint(.primary)` to
                // neutralise the per-doc `effectiveAccentColor` that
                // propagates through the env from the LeafView body.
                // Without this, leaves whose accent is a muted hue
                // (or whose `vm.accentColor` resolves to a pale tone)
                // render the menu icons as visibly "greyed", while
                // brighter accents render them crisp white — same
                // menu, two different reads. Tinting at the Menu's
                // *trigger* (line ~333) only affects the ellipsis
                // glyph, not the inner items in iOS 26. The accent-
                // colour picker's swatches are rasterised UIImages,
                // so `.tint(.primary)` doesn't repaint them.
                Group {
                // Apple-Music-style icon-and-label row at the top of the
                // overflow menu : `.controlGroupStyle(.menu)` lays the
                // two actions out horizontally as labeled icon buttons
                // inside the menu. Lock duplicates the standalone
                // padlock in the toolbar (Notes-app pattern : a
                // primary action that's important enough to be one
                // tap and also live next to the other doc settings).
                ControlGroup {
                    Button {
                        Haptic.toggle()
                        vm.saveLocked(!vm.locked)
                    } label: {
                        Label(vm.locked ? "Unlock" : "Lock",
                              systemImage: vm.locked ? "lock.fill" : "lock.open.fill")
                    }
                    // Pin / Unpin — same one-tap affordance as Lock,
                    // duplicated in the bottom section of the menu for
                    // discoverability via the row long-press too. Reads
                    // the live pinned state from `store.allLeaves` so
                    // the label flips immediately after toggling.
                    Button {
                        Haptic.toggle()
                        let isPinned = (store.allLeaves
                            .first(where: { $0.id == vm.leafId })?.pinnedAt ?? "")
                            .isEmpty == false
                        store.setLeafPinned(leafId: vm.leafId, pinned: !isPinned)
                    } label: {
                        let isPinned = (store.allLeaves
                            .first(where: { $0.id == vm.leafId })?.pinnedAt ?? "")
                            .isEmpty == false
                        Label(isPinned ? "Unpin" : "Pin",
                              systemImage: isPinned ? "pin.slash" : "pin")
                    }
                    if let shareURL = URL(string: "pinkha://leaf/\(vm.leafId)") {
                        ShareLink(item: shareURL,
                                  subject: Text(vm.title.isEmpty
                                                ? String(localized: "Untitled")
                                                : vm.title)) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .controlGroupStyle(.menu)
                // iOS 26 quirk : `ControlGroup(.menu)` inside a Menu
                // renders its child buttons with the parent ToolbarItem's
                // accessibility / enabled state baked in. When the
                // toolbar's neighbour sort-button is `.disabled(vm.locked)`
                // and the leaf is UNLOCKED, the group's three buttons
                // (Lock / Pin / Share) inherit a subtle dim that the
                // outer Group's `.environment(\.isEnabled, true)` doesn't
                // override (the env is re-evaluated inside the menu's
                // popover scope). Pinning the modifiers DIRECTLY on the
                // ControlGroup forces full opacity regardless of the
                // toolbar's neighbour states.
                .tint(.primary)
                .environment(\.isEnabled, true)
                .foregroundStyle(.primary)

                Menu {
                    Button {
                        Haptic.tap()
                        vm.saveAccentColor(nil)
                    } label: {
                        Label {
                            Text("Use default")
                        } icon: {
                            Image(systemName: "circle.dashed")
                        }
                    }
                    ForEach(BlockColorOption.palette) { option in
                        Button {
                            Haptic.tap()
                            vm.saveAccentColor(option.name)
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
                        Text("Accent color")
                    } icon: {
                        // Filled paintbrush in the overflow menu when
                        // an explicit accent is set; outline otherwise.
                        Image(systemName: vm.accentColor == nil
                              ? "paintbrush"
                              : "paintbrush.fill")
                    }
                }
                Menu {
                    Button {
                        Haptic.tap()
                        vm.saveTextDirection(nil)
                    } label: {
                        Label {
                            Text("System default")
                        } icon: {
                            Image(systemName: "circle.dashed")
                        }
                    }
                    Button {
                        Haptic.tap()
                        vm.saveTextDirection("ltr")
                    } label: {
                        Label {
                            Text("Left to right")
                        } icon: {
                            Image(systemName: "text.alignleft")
                        }
                    }
                    Button {
                        Haptic.tap()
                        vm.saveTextDirection("rtl")
                    } label: {
                        Label {
                            Text("Right to left")
                        } icon: {
                            Image(systemName: "text.alignright")
                        }
                    }
                } label: {
                    Label {
                        Text("Text direction")
                    } icon: {
                        Image(systemName: vm.textDirection == "rtl"
                              ? "text.alignright"
                              : (vm.textDirection == "ltr"
                                 ? "text.alignleft"
                                 : "text.justify"))
                    }
                }
                // Books-style theme picker — per-doc override of the
                // app-wide theme from Settings. "Use default" clears
                // the override so the doc inherits whatever the user
                // chose globally; the label spells out the current
                // default so the user can tell what "default" maps
                // to right now. A `state = .on` mark on the active
                // entry signals which one is effective.
                Menu {
                    Button {
                        Haptic.tap()
                        vm.saveTheme(nil)
                    } label: {
                        if vm.theme == nil {
                            Label {
                                Text("Match Settings (\(settings.theme.labelString))")
                            } icon: {
                                Image(systemName: "checkmark")
                            }
                        } else {
                            Label {
                                Text("Match Settings (\(settings.theme.labelString))")
                            } icon: {
                                Image(systemName: "circle.dashed")
                            }
                        }
                    }
                    ForEach(AppSettings.Theme.allCases) { theme in
                        Button {
                            Haptic.tap()
                            vm.saveTheme(theme.rawValue)
                        } label: {
                            if vm.theme == theme.rawValue {
                                Label {
                                    Text(theme.label)
                                } icon: {
                                    Image(systemName: "checkmark")
                                }
                            } else {
                                Text(theme.label)
                            }
                        }
                    }
                } label: {
                    Label {
                        Text("Theme")
                    } icon: {
                        Image(systemName: "book.pages")
                    }
                }
                Divider()
                Button {
                    Haptic.tap()
                    showingPublishDateSheet = true
                } label: {
                    Label {
                        Text("Publish date")
                    } icon: {
                        Image(systemName: "paperplane")
                    }
                }
                Button {
                    Haptic.tap()
                    showingAttachToBookSheet = true
                } label: {
                    Label {
                        Text("Add to a book")
                    } icon: {
                        Image(systemName: "book.and.wrench.fill")
                    }
                }
                Divider()
                // Reader mode entry — parallel to the CreateBubble's
                // own ⋯ entry (which is unreachable inside a leaf when
                // PRO-60's auto-hide is on). Toggles the global reader
                // controller ; the floating eyeglasses.slash button at
                // the root brings the chrome back.
                Button {
                    readerMode.toggle()
                } label: {
                    Label {
                        Text("Reader mode")
                    } icon: {
                        Image(systemName: "eyeglasses")
                    }
                }
                }
                .tint(.primary)
                // Override the parent toolbar's `.disabled(vm.locked)`
                // env so the Menu items NEVER inherit a dimmed state.
                // Without this, created (unlocked) leaves show a
                // muted menu while imported (locked) leaves show a
                // crisp one — iOS 26 propagates `isEnabled` from the
                // sibling toolbar buttons down into the Menu's
                // content unless we explicitly opt out here.
                .environment(\.isEnabled, true)
                // Explicit foreground style — defensive. `.tint` only
                // recolors interactive controls ; `.foregroundStyle`
                // pins the icon/text rendering to primary regardless
                // of inherited content opacity tuning.
                .foregroundStyle(.primary)
            } label: {
                Image(systemName: "ellipsis")
            }
            // Neutral chrome by default — the per-doc accent only
            // shows up inside the menu's swatches, the trigger itself
            // stays quiet.
            .tint(.primary)
            .accessibilityLabel("Leaf options")
        }
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
        if !readerMode.isActive {
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
