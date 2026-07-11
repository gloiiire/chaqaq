import SwiftUI
import PinkhaFFI
import PinkhaCore
import PinkhaComposer
import PinkhaDesignSystem

// ── Leaf view ─────────────────────────────────────────────────────────────

/// Full-screen leaf editor: cover + icon, title, block list, FAB, undo/redo pill.
public struct LeafView: View {
    /// `@Bindable` (not `@State`) because the VM is owned by `TabManager`
    /// — LeafView is recreated on every push but the VM lives for as
    /// long as the tab is open, keeping its blocks/undo/burst state alive
    /// across navigations à la Safari.
    @Bindable var vm: LeafViewModel
    /// Injected by `ContentView` so we can flip the global creation
    /// context to this leaf while it's on screen — `New …` from
    /// the bubble then creates child leaves or embedded books inside
    /// this doc, à la Notion.
    @Environment(Composer.self) var composer
    @Environment(TabManager.self) var tabManager
    /// Lets the overflow menu surface a "Reader mode" entry — the
    /// CreateBubble's ⋯ entry is unreachable when the user is inside
    /// a leaf with PRO-60's auto-hide enabled (the bubble is hidden),
    /// so a parallel entry in the leaf's own toolbar is required.
    @Environment(ReaderMode.self) var readerMode
    /// Read-only here — drives the optional spotlight tint applied in
    /// `blockListRow`. The setting is owned at the app level so every
    /// leaf picks the same look without having to re-fetch it.
    @Environment(AppSettings.self) var settings
    /// Used by the breadcrumb in the toolbar to walk up the
    /// parent-doc chain (`parentLeafId` is on the metadata, not on
    /// the active VM).
    @Environment(PinkhaStore.self) var store
    /// Tracks whether the iOS 26 bottom accessory is rendered inline
    /// (collapsed into the tab bar) or expanded above it. Drives the
    /// floating-button bottom padding so the visual gap to the
    /// accessory bar stays consistent in both modes.
    @Environment(\.tabViewBottomAccessoryPlacement) var accessoryPlacement
    /// Pops the editor when the title-bubble menu confirms a delete.
    @Environment(\.dismiss) var dismiss
    @State var showingBlockPicker = false
    @State var editMode: EditMode = .inactive
    @State var focusTitle = false
    @State var titleFocusOffset: Int? = nil
    @State var titleInNavBar = false
    @State var documentIcon: String?
    @State var recentEmojis: [String]
    @State var selectedBlocks: Set<String> = []
    @State var keyboardVisible = false
    /// Set when the user taps a `pinkha://leaf/{uuid}` link inside the
    /// editor. The `navigationDestination` below pushes a new
    /// `LeafView` whenever this becomes non-nil — the mention link
    /// resolves to an internal navigation rather than an external URL open.
    @State var pushedLeafId: String? = nil
    /// Drives the morphing block FAB on the right. When true, the
    /// pencil button has stretched into the quick-insert capsule;
    /// the UndoRedoPill on the left hides itself to give the morph
    /// room to breathe.
    @State var blockFABExpanded: Bool = false
    /// `true` while the toolbar's overflow `…` Menu popover is on
    /// screen. iOS 26 dims the popover whenever a `.glassEffect()`
    /// overlay is visible underneath it (FAB + UndoRedoPill in our
    /// layout). Driven by an invisible `Color.clear` placed at the
    /// top of the Menu's content — its `onAppear` / `onDisappear`
    /// fire on present / dismiss. While `true`, `overlayButtons`
    /// hides the FAB + UndoRedoPill so the popover renders bright.
    @State var isOverflowMenuOpen: Bool = false
    /// Bible-Strong-style spotlight: when the doc is opened from a search
    /// hit, the matched block stays sharp while the rest of the page is
    /// blurred + dimmed. Cleared on the first user interaction (tap or
    /// scroll) so editing resumes naturally.
    @State var spotlightBlockId: String? = nil
    /// Locks the auto-spotlight to the very first scroll movement we
    /// initiated — without this, the programmatic `proxy.scrollTo` below
    /// would itself trigger the "user scrolled, drop the spotlight" path.
    @State var spotlightArmedAt: Date? = nil
    /// Cache of `id → metadata` for every non-deleted doc, used to
    /// walk the `parentLeafId` chain for the breadcrumb. Loaded once
    /// on appear from `vm.api.listLeaves()` (which includes
    /// sub-pages, unlike `store.leaves` which is root-only).
    @State var docMetaById: [String: LeafMetaFfi] = [:]
    /// Presents the graphical date picker that lets the user
    /// override (or reset) the leaf's publish date — separate
    /// from the immutable creation timestamp. Triggered from the
    /// overflow menu in the toolbar.
    @State var showingPublishDateSheet = false
    /// Presents the "Add to a book" sheet — picks a target DB
    /// and edits its row's property values for this leaf.
    /// Triggered from the overflow menu in the toolbar.
    @State var showingAttachToBookSheet = false
    /// Legacy UserDefaults key for the lock state, retained for the one-shot
    /// migration in `onAppear` — the canonical store is now `vm.locked`.
    let lockKey: String
    let iconKey: String

    var onDisappear: (() -> Void)? = nil
    /// Optional block UUID to scroll to once the leaf finishes
    /// loading. Set by callers like the search view so a hit jumps
    /// straight to the matched block instead of the top of the doc.
    let scrollToBlockId: String?

    /// Build a LeafView around an existing VM (the typical path —
    /// callers fetch the VM from `TabManager.open(leafId:)` so the
    /// tab keeps its in-memory state).
    public init(vm: LeafViewModel,
         onDisappear: (() -> Void)? = nil,
         scrollToBlockId: String? = nil) {
        let leafId = vm.leafId
        let lockKey = Self.lockKeyFor(leafId: leafId)
        let iconKey = Self.iconKeyFor(leafId: leafId)
        self.vm = vm
        _documentIcon = State(initialValue: UserDefaults.standard.string(forKey: iconKey))
        _recentEmojis = State(initialValue: loadRecentEmojis())
        self.lockKey = lockKey
        self.iconKey = iconKey
        self.onDisappear = onDisappear
        self.scrollToBlockId = scrollToBlockId
    }

    public var body: some View {
        // ScrollViewReader gives us `proxy.scrollTo(id:)` for search
        // hits, but it doubles as a SwiftUI preference container —
        // when a `.toolbar` modifier and per-row `.background` /
        // `.blur` / `.animation` modifiers all live inside its closure,
        // mutating any @State during a `withAnimation` triggers an
        // infinite preference-update loop in AttributeGraph (logged in
        // Sentry as a recursive `DynamicPreferenceCombiner` chain →
        // stack overflow).
        //
        // Mitigations:
        //   1. State mutations land on a fresh runloop turn via
        //      `.task(id:)` instead of `onAppear + asyncAfter`, so
        //      `spotlightBlockId` is never written during the same
        //      layout pass that materialises the rows.
        //   2. The global `.simultaneousGesture(TapGesture)` was
        //      removed — the scroll-driven `dismissSpotlight()` in
        //      `documentList.onScrollGeometryChange` is enough to cover
        //      "user takes back control."
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                documentList
                    .onChange(of: vm.activeBlockId) { _, newId in
                        guard let id = newId else { return }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(420))
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.9))
                            }
                        }
                    }
                    .task(id: scrollToBlockId) {
                        guard let target = scrollToBlockId else { return }
                        try? await Task.sleep(for: .milliseconds(350))
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                        try? await Task.sleep(for: .milliseconds(150))
                        withAnimation(.easeInOut(duration: 0.35)) {
                            spotlightBlockId = target
                            spotlightArmedAt = Date()
                        }
                    }
                overlayButtons
            }
        }
    }

    // ── Main list ────────────────────────────────────────────────────────────

    var documentList: some View {
        List {
            // LeafDecorView always renders — even in reader mode. The
            // cover and the icon are part of the doc's identity, and
            // the "Add cover / Add icon" placeholders (when neither is
            // set) are part of the leaf layout, not interactive nav
            // chrome. Reader mode strips toolbar, tab bar, undo/redo,
            // FAB, AddBlockButton — the document content stays.
            LeafDecorView(
                cover: vm.cover, icone: vm.icon, recentEmojis: recentEmojis,
                verrouille: vm.locked,
                onCouverture: { vm.saveCover($0) },
                onImageData: { data in vm.saveCoverImage(data: data) },
                onImageFichier: { url in vm.saveCoverImageFromFile(url) },
                onIcone: { nouvelleIcone in
                    // The icon is now persisted in the Rust leaf via the
                    // FFI — same model as the cover. The legacy UserDefaults
                    // fallback is kept for newly-typed emojis (we still track
                    // the "recently used" list in UserDefaults) but the
                    // canonical store is SQLite.
                    vm.saveIcon(nouvelleIcone)
                    if let nouvelleIcone {
                        recentEmojis = saveRecentEmoji(nouvelleIcone)
                    }
                }
            )
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets()).moveDisabled(true).deleteDisabled(true)

            LeafTitleView(title: $vm.title, focusDemande: $focusTitle,
                              focusCursorOffset: $titleFocusOffset,
                              onSave: vm.saveTitle,
                              onNewBlock: { tail in
                                  let spans = tail.isEmpty ? [] : [InlineTextFfi(content: tail, styles: [])]
                                  vm.addBlock(type: .text, initialSpans: spans, atStart: true)
                              },
                              themeForeground: effectiveTheme.foregroundColor.map(UIColor.init),
                              keyboardAppearance: effectiveKeyboardAppearance)
                .disabled(vm.locked)
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 8, trailing: 20))
                .moveDisabled(true).deleteDisabled(true)

            // DIAGNOSTIC PRO-61 bisect step 2 : re-enable the two
            // NON-glass list rows (EmptyEditorState + AddBlockButton)
            // while keeping the FAB + UndoRedoPill glass overlays
            // disabled (in LeafView+Toolbar.swift overlayButtons).
            // If menu stays bright, confirms it's the glass overlays
            // that trigger the popover dim.
            if vm.blocks.isEmpty && !vm.locked {
                EmptyEditorState { vm.addBlock(type: .text) }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .moveDisabled(true).deleteDisabled(true)
            }

            // iOS 27's `.reorderable()` / `.reorderContainer(for:)` pair
            // replaces the classic `.onMove` handler with a diff-based API
            // — cleaner, no EditMode toggling, cross-container support ready.
            // Under iOS 26 we keep the working `.onMove` path.
            if #available(iOS 27.0, *) {
                ForEach($vm.blocks) { $block in blockListRow($block) }
                    .reorderable()
            } else {
                ForEach($vm.blocks) { $block in blockListRow($block) }
                    .onMove(perform: vm.moveBlock)
            }

            if !vm.locked && !readerMode.isActive {
                AddBlockButton { showingBlockPicker = true }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 70, trailing: 20))
                    .moveDisabled(true).deleteDisabled(true)
            }
        }
        .listStyle(.plain)
        .modifier(BlockReorderContainerModifier(vm: vm))
        .ignoresSafeArea(.container, edges: vm.cover == nil ? [] : .top)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, offset in
            // `onScrollGeometryChange` fires every frame while the
            // user drags. Unconditionally calling `withAnimation`
            // opens a SwiftUI transaction even when the bool flag
            // doesn't change, which compounds into per-frame jank
            // on docs with few blocks (no other expensive content
            // soaks the cost). Compare first, mutate only on the
            // boundary crossing.
            let shouldShow = offset > 60
            if shouldShow != titleInNavBar {
                withAnimation(.easeInOut(duration: 0.15)) {
                    titleInNavBar = shouldShow
                }
            }
            // Drop the spotlight as soon as the user takes over the scroll.
            // The 0.6s grace window lets our own programmatic scrollTo
            // settle without triggering this path.
            if let armedAt = spotlightArmedAt,
               Date().timeIntervalSince(armedAt) > 0.6,
               spotlightBlockId != nil {
                dismissSpotlight()
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .environment(\.editMode, $editMode)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // iOS 26 Liquid Glass : the toolbar background uses an adaptive
        // glass material that reads the surface underneath (cover image
        // or page) and re-vibrancies its symbols accordingly — exactly
        // what Mail does. Forcing `.dark` colorScheme on covered docs
        // used to make symbols white-on-white over light cover images.
        .toolbarBackground(.automatic, for: .navigationBar)
        .toolbar { documentToolbar }
        // Reader mode : when active, hide every chrome surface so the
        // leaf content fills the screen edge-to-edge. The tab bar
        // disappears too because LeafView's NavigationStack lives
        // inside the root TabView — `.toolbar(.hidden, for: .tabBar)`
        // applied here propagates up. The floating exit button at the
        // root (ContentView) remains visible as the always-discoverable
        // escape hatch ; the multi-finger long-press still toggles back.
        .toolbar(readerMode.isActive ? .hidden : .visible, for: .navigationBar)
        .toolbar(readerMode.isActive ? .hidden : .visible, for: .tabBar)
        // iOS 27 opt-in: outside reader mode, the nav bar auto-minimises
        // when the user scrolls down through a long doc (Safari-style)
        // and restores when they reverse direction. In reader mode the
        // bar is fully hidden by the modifiers above so minimisation is
        // irrelevant. iOS 26 falls back to the fixed nav bar (no-op).
        .modifier(LeafNavBarMinimizationModifier(active: !readerMode.isActive))
        // `.persistentSystemOverlays(.hidden)` is the iOS 16+ way to
        // collapse the home-indicator gloss + any system-reserved
        // bottom slot. Without it, the `.tabViewBottomAccessory` slot
        // keeps a thin shadow band reserved at the bottom of the screen
        // even when the accessory content is empty.
        .persistentSystemOverlays(readerMode.isActive ? .hidden : .automatic)
        // When `.toolbar(.hidden, for: .navigationBar)` fires, iOS not
        // only hides the chrome — it also reclaims the bar's ~44 pt of
        // safe-area inset, so the list content jumps upward to fill
        // the gap. Reader mode wants the chrome gone but the layout to
        // stay put (otherwise the cover/title shift annoyingly each
        // time the user toggles). Re-injecting an equivalent invisible
        // top inset keeps the document anchored exactly where it was.
        .safeAreaInset(edge: .top, spacing: 0) {
            if readerMode.isActive {
                Color.clear.frame(height: 54)
            }
        }
        // Per-doc accent overrides the global setting for the whole
        // editor — toolbar buttons, swipe action buttons, the cursor
        // (UIKit reads the env tint), etc. all repaint when
        // `vm.accentColor` changes. Explicit `effectiveAccentColor`
        // call so `nil` falls back to `settings.accentColor`.
        .tint(effectiveAccentColor)
        // Books-style theme : tint the doc surface + force a matching
        // colorScheme so system widgets (cursor, scrollbar, blur)
        // align with the palette. `.original` is a no-op so iOS
        // light/dark continues to drive the look.
        .scrollContentBackground(.hidden)
        .background(effectiveTheme.backgroundColor ?? Color.pinkhaSurface)
        .preferredColorScheme(effectiveTheme.colorScheme)
        // SwiftUI `.preferredColorScheme` alone isn't enough when the
        // app-wide `applyAppearanceToWindows()` already pinned the
        // window's `overrideUserInterfaceStyle` — UIKit window
        // overrides supersede every SwiftUI view-level preference,
        // so `UIColor.label` inside the textViews stays on the
        // global scheme and the per-doc theme's body text ends up
        // unreadable (white text on a papier-light doc and the
        // reverse). Mirror the doc's effective scheme onto the window
        // while the editor is on screen, then restore the global
        // appearance when the user leaves.
        .onChange(of: effectiveTheme) { _, _ in syncWindowTheme() }
        .onAppear { syncWindowTheme() }
        // Capture a screenshot when the user navigates away — fuels
        // the tab switcher's Safari-style "live thumbnail at last
        // scroll position" preview. Lives in the body (invisible,
        // 0-sized) so its hosting VC's `viewWillDisappear` fires
        // exactly when the editor is still on screen for the final
        // frame.
        .background(LeafSnapshotHook(leafId: vm.leafId).frame(width: 0, height: 0))
        .onReceive(NotificationCenter.default.publisher(
            for: Composer.popToDocNotification)) { note in
            // Breadcrumb tapped an ancestor. We need to clear
            // `pushedLeafId` on:
            //  - the target itself (so the NavStack pops the
            //    descendant chain rooted at its `navigationDestination`
            //    binding), AND
            //  - every doc strictly between target and current — even
            //    though they'll be unmounted, clearing defensively
            //    prevents a transient body re-eval from re-pushing
            //    the popped descendant while SwiftUI is still
            //    tearing the chain down. Needed at depth ≥ 3.
            guard let target = note.userInfo?["leafId"] as? String
            else { return }
            if target == vm.leafId || isDescendant(of: target) {
                pushedLeafId = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: Composer.docTitleChangedNotification)) { _ in
            // Some doc's title was just persisted — refresh our
            // copy of every doc's metadata so the breadcrumb walks
            // the chain with fresh titles. Cheap (in-memory + one
            // SQLite read) and only fires on actual title saves.
            if let all = try? vm.api.listLeaves() {
                docMetaById = Dictionary(uniqueKeysWithValues:
                    all.map { ($0.id, $0) })
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { keyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { keyboardVisible = false }
        }
        // PRO-61 : detect when the toolbar's overflow Menu popover is
        // on screen. iOS 26 presents menu popovers in their OWN
        // `UIWindow` (a private subclass that becomes key while the
        // popover is visible). We observe key-window changes : when
        // a new key window appears that isn't our main scene window,
        // a popover is showing → hide the glass overlays so the menu
        // renders bright. When our main window becomes key again,
        // the popover dismissed → restore the overlays.
        .onAppear {
            vm.load()
            composer.currentContext = .leaf(id: vm.leafId)
            // Load every doc's metadata (root + sub-pages) so the
            // breadcrumb in the toolbar can walk the `parentLeafId`
            // chain. `store.leaves` only contains root pages.
            if let all = try? vm.api.listLeaves() {
                docMetaById = Dictionary(uniqueKeysWithValues:
                    all.map { ($0.id, $0) })
            }
            // Mark this doc as an open tab in the switcher. Done here
            // (in `onAppear`) rather than at NavigationLink build time
            // so SwiftUI body re-renders don't keep re-adding tabs the
            // user just closed via the Safari-style switcher.
            tabManager.markOpened(leafId: vm.leafId, api: vm.api)
            // One-shot migration: leaves created before the icon moved
            // to the Rust domain stored their emoji in UserDefaults. Carry
            // it over to the freshly-loaded leaf, then clear the legacy
            // entry so the migration runs at most once per doc.
            if vm.icon == nil,
               let legacy = UserDefaults.standard.string(forKey: iconKey) {
                vm.saveIcon(legacy)
                UserDefaults.standard.removeObject(forKey: iconKey)
            }
            // Same migration for the lock flag — was in UserDefaults, now
            // lives on Leaf.locked. Only migrate when the loaded doc is
            // NOT already locked (avoids clobbering imports which default to
            // locked = true on the Rust side).
            if !vm.locked, UserDefaults.standard.object(forKey: lockKey) != nil {
                let legacyLocked = UserDefaults.standard.bool(forKey: lockKey)
                if legacyLocked { vm.saveLocked(true) }
                UserDefaults.standard.removeObject(forKey: lockKey)
            }
        }
        .onDisappear {
            vm.flushAllBursts()
            vm.saveTitle()
            // Only reset the creation context to `.root` if it still
            // points at this doc. When the user pushes a sub-page,
            // SwiftUI may fire B.onAppear (set `.leaf(B)`)
            // before A.onDisappear here — blindly resetting would
            // clobber B's just-set context and any new leaf created
            // from inside B would land at the library root.
            if composer.currentContext == .leaf(id: vm.leafId) {
                composer.currentContext = .root
            }
            // Restore the global appearance — the doc's window theme
            // override only lives while the editor is on screen.
            settings.applyAppearanceToWindows()
            onDisappear?()
        }
        // When the bubble creates a child leaf from inside this doc, the
        // composer signals here. We flush pending edits, insert the Page
        // block via the VM (keeps blocks/snapshots in sync) and consume
        // the signal so it doesn't fire twice.
        .onChange(of: composer.pendingChildPage) { _, pending in
            guard let pending, pending.parentLeafId == vm.leafId else { return }
            vm.flushAllBursts()
            vm.addChildLeafBlock(childLeafId: pending.childLeafId)
            composer.pendingChildPage = nil
        }
        .sheet(isPresented: $showingBlockPicker) {
            BlockPickerSheet { type in vm.addBlock(type: type, afterId: vm.activeBlockId) }
        }
        .sheet(isPresented: $showingPublishDateSheet) {
            LeafPublishDateSheet(
                createdAt: vm.createdAt,
                publishedAt: vm.publishedAt,
                onSave: { iso in vm.savePublishedAt(iso) }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingAttachToBookSheet) {
            BindLeafToBookSheet(leafId: vm.leafId)
                .environment(store)
                .presentationDetents([.large])
        }
        .alert("Error", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: { Text(vm.errorMessage ?? "") }
        // Internal-link navigation: tapping a `pinkha://leaf/{uuid}` link in
        // a block pushes a fresh LeafView onto the same NavigationStack.
        // The destination view runs through `onAppear { vm.load() }`, so the
        // target leaf loads from SQLite without any extra plumbing.
        .navigationDestination(item: $pushedLeafId) { leafId in
            LeafView(vm: tabManager.open(leafId: leafId, api: vm.api), onDisappear: nil)
                // Mention-link pushes are editorial navigation — a Books-style
                // crossfade reads better than a hard slide. The list-driven
                // push in `LibraryView` keeps its zoom (Notes-style tile
                // expansion, more physical). iOS 26 falls back to the
                // default push transition.
                .modifier(MentionLinkCrossFadeModifier())
        }
    }

    // ── Selection / helpers ───────────────────────────────────────────────────

    func selectionButton(_ id: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { toggleSelection(id) }
        } label: {
            Image(systemName: selectedBlocks.contains(id) ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selectedBlocks.contains(id) ? effectiveAccentColor : .secondary)
                .frame(width: 28, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func toggleSelection(_ id: String) {
        if selectedBlocks.contains(id) { selectedBlocks.remove(id) } else { selectedBlocks.insert(id) }
    }

    /// Fades out the search-hit spotlight, restoring the rest of the doc
    /// Mirrors the doc's effective Books-theme `colorScheme` onto the
    /// window's UIKit `overrideUserInterfaceStyle`. SwiftUI's
    /// `.preferredColorScheme` alone can't beat the window-level
    /// override `applyAppearanceToWindows()` already sets at app
    /// startup, so `UIColor.label` inside the editor's `UITextView`s
    /// would otherwise stay on the global scheme — making the
    /// per-doc theme's body text unreadable. When the theme is
    /// `.original` (no explicit scheme), fall back to whatever the
    /// global appearance setting wants.
    func syncWindowTheme() {
        let style: UIUserInterfaceStyle
        switch effectiveTheme.colorScheme {
        case .light: style = .light
        case .dark:  style = .dark
        case nil, .some(_):
            switch settings.appearance {
            case .system: style = .unspecified
            case .light:  style = .light
            case .dark:   style = .dark
            }
        }
        // Short-circuit when the key window already has the right
        // style — `overrideUserInterfaceStyle = …` forces a layout
        // pass on every descendant view, and re-doing it on every
        // body re-eval (including the snapshot SwiftUI takes when
        // the app goes to background) is what made the global
        // re-render visibly slow at app-quit time.
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        if windows.first?.overrideUserInterfaceStyle == style { return }
        // Match `AppSettings.applyAppearanceToWindows` : animate the
        // override flip so the NavStack-↔-home transition looks
        // smooth instead of snapping into the new colour scheme.
        UIView.animate(withDuration: 0.25) {
            windows.forEach { $0.overrideUserInterfaceStyle = style }
        }
    }

    /// to full clarity. Safe to call when no spotlight is active.
    func dismissSpotlight() {
        guard spotlightBlockId != nil else { return }
        withAnimation(.easeOut(duration: 0.3)) {
            spotlightBlockId = nil
        }
        spotlightArmedAt = nil
    }

    func selectFromLongPress(_ id: String) {
        guard !vm.locked else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            editMode = .active; selectedBlocks.insert(id)
            focusTitle = false; vm.stopNavigationRepeat()
        }
    }

    func deleteSelectedBlocks() {
        let ids = selectedBlocks
        withAnimation(.easeInOut(duration: 0.18)) { selectedBlocks.removeAll(); vm.deleteBlocks(ids: ids) }
    }

    static func lockKeyFor(leafId: String) -> String { "leaf.locked.\(leafId)" }
    static func iconKeyFor(leafId: String) -> String { "leaf.icon.\(leafId)" }
}
