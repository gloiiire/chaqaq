import SwiftUI

// ── Document view ─────────────────────────────────────────────────────────────

/// Full-screen document editor: cover + icon, title, block list, FAB, undo/redo pill.
struct DocumentView: View {
    /// `@ObservedObject` (not `@StateObject`) because the VM is owned
    /// by `TabManager` — DocumentView is recreated on every push but
    /// the VM lives for as long as the tab is open, keeping its
    /// blocks/undo/burst state alive across navigations à la Safari.
    @ObservedObject var vm: DocumentViewModel
    /// Injected by `ContentView` so we can flip the global creation
    /// context to this document while it's on screen — `New …` from
    /// the bubble then creates child pages or embedded databases inside
    /// this doc, à la Notion.
    @EnvironmentObject var composer: Composer
    @EnvironmentObject var tabManager: TabManager
    /// Read-only here — drives the optional spotlight tint applied in
    /// `blockListRow`. The setting is owned at the app level so every
    /// document picks the same look without having to re-fetch it.
    @EnvironmentObject var settings: AppSettings
    /// Used by the breadcrumb in the toolbar to walk up the
    /// parent-doc chain (`parentDocId` is on the metadata, not on
    /// the active VM).
    @EnvironmentObject var store: PinkhaStore
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
    /// Set when the user taps a `pinkha://doc/{uuid}` link inside the
    /// editor. The `navigationDestination` below pushes a new
    /// `DocumentView` whenever this becomes non-nil — the mention link
    /// resolves to an internal navigation rather than an external URL open.
    @State var pushedDocId: String? = nil
    /// Drives the morphing block FAB on the right. When true, the
    /// pencil button has stretched into the quick-insert capsule;
    /// the UndoRedoPill on the left hides itself to give the morph
    /// room to breathe.
    @State var blockFABExpanded: Bool = false
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
    /// walk the `parentDocId` chain for the breadcrumb. Loaded once
    /// on appear from `vm.api.listDocuments()` (which includes
    /// sub-pages, unlike `store.documents` which is root-only).
    @State var docMetaById: [String: DocumentMetaFfi] = [:]
    /// Legacy UserDefaults key for the lock state, retained for the one-shot
    /// migration in `onAppear` — the canonical store is now `vm.locked`.
    let lockKey: String
    let iconKey: String

    var onDisappear: (() -> Void)? = nil
    /// Optional block UUID to scroll to once the document finishes
    /// loading. Set by callers like the search view so a hit jumps
    /// straight to the matched block instead of the top of the doc.
    let scrollToBlockId: String?

    /// Build a DocumentView around an existing VM (the typical path —
    /// callers fetch the VM from `TabManager.open(docId:)` so the
    /// tab keeps its in-memory state).
    init(vm: DocumentViewModel,
         onDisappear: (() -> Void)? = nil,
         scrollToBlockId: String? = nil) {
        let docId = vm.docId
        let lockKey = Self.lockKeyFor(docId: docId)
        let iconKey = Self.iconKeyFor(docId: docId)
        self.vm = vm
        _documentIcon = State(initialValue: UserDefaults.standard.string(forKey: iconKey))
        _recentEmojis = State(initialValue: loadRecentEmojis())
        self.lockKey = lockKey
        self.iconKey = iconKey
        self.onDisappear = onDisappear
        self.scrollToBlockId = scrollToBlockId
    }

    var body: some View {
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
            DocumentDecorView(
                cover: vm.cover, icone: vm.icon, recentEmojis: recentEmojis,
                verrouille: vm.locked,
                onCouverture: { vm.saveCover($0) },
                onImageData: { data in vm.saveCoverImage(data: data) },
                onImageFichier: { url in vm.saveCoverImageFromFile(url) },
                onIcone: { nouvelleIcone in
                    // The icon is now persisted in the Rust document via the
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

            DocumentTitleView(title: $vm.title, focusDemande: $focusTitle,
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

            if vm.blocks.isEmpty && !vm.locked {
                EmptyEditorState { vm.addBlock(type: .text) }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .moveDisabled(true).deleteDisabled(true)
            }

            ForEach($vm.blocks) { $block in blockListRow($block) }
                .onMove(perform: vm.moveBlock)

            if !vm.locked {
                AddBlockButton { showingBlockPicker = true }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    // Extra bottom inset so the "+ New block" sits well
                    // above the floating undo/redo + FAB buttons below
                    // and isn't half-hidden behind them.
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 70, trailing: 20))
                    .moveDisabled(true).deleteDisabled(true)
            }
        }
        .listStyle(.plain)
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
        .background(effectiveTheme.backgroundColor ?? Color(uiColor: .systemBackground))
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
        .background(DocumentSnapshotHook(docId: vm.docId).frame(width: 0, height: 0))
        .onReceive(NotificationCenter.default.publisher(
            for: Composer.popToDocNotification)) { note in
            // Breadcrumb tapped an ancestor. We need to clear
            // `pushedDocId` on:
            //  - the target itself (so the NavStack pops the
            //    descendant chain rooted at its `navigationDestination`
            //    binding), AND
            //  - every doc strictly between target and current — even
            //    though they'll be unmounted, clearing defensively
            //    prevents a transient body re-eval from re-pushing
            //    the popped descendant while SwiftUI is still
            //    tearing the chain down. Needed at depth ≥ 3.
            guard let target = note.userInfo?["docId"] as? String
            else { return }
            if target == vm.docId || isDescendant(of: target) {
                pushedDocId = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: Composer.docTitleChangedNotification)) { _ in
            // Some doc's title was just persisted — refresh our
            // copy of every doc's metadata so the breadcrumb walks
            // the chain with fresh titles. Cheap (in-memory + one
            // SQLite read) and only fires on actual title saves.
            if let all = try? vm.api.listDocuments() {
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
        .onAppear {
            vm.load()
            composer.currentContext = .document(id: vm.docId)
            // Load every doc's metadata (root + sub-pages) so the
            // breadcrumb in the toolbar can walk the `parentDocId`
            // chain. `store.documents` only contains root pages.
            if let all = try? vm.api.listDocuments() {
                docMetaById = Dictionary(uniqueKeysWithValues:
                    all.map { ($0.id, $0) })
            }
            // Mark this doc as an open tab in the switcher. Done here
            // (in `onAppear`) rather than at NavigationLink build time
            // so SwiftUI body re-renders don't keep re-adding tabs the
            // user just closed via the Safari-style switcher.
            tabManager.markOpened(docId: vm.docId, api: vm.api)
            // One-shot migration: documents created before the icon moved
            // to the Rust domain stored their emoji in UserDefaults. Carry
            // it over to the freshly-loaded document, then clear the legacy
            // entry so the migration runs at most once per doc.
            if vm.icon == nil,
               let legacy = UserDefaults.standard.string(forKey: iconKey) {
                vm.saveIcon(legacy)
                UserDefaults.standard.removeObject(forKey: iconKey)
            }
            // Same migration for the lock flag — was in UserDefaults, now
            // lives on Document.locked. Only migrate when the loaded doc is
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
            // SwiftUI may fire B.onAppear (set `.document(B)`)
            // before A.onDisappear here — blindly resetting would
            // clobber B's just-set context and any new note created
            // from inside B would land at the workspace root.
            if composer.currentContext == .document(id: vm.docId) {
                composer.currentContext = .root
            }
            // Restore the global appearance — the doc's window theme
            // override only lives while the editor is on screen.
            settings.applyAppearanceToWindows()
            onDisappear?()
        }
        // When the bubble creates a child page from inside this doc, the
        // composer signals here. We flush pending edits, insert the Page
        // block via the VM (keeps blocks/snapshots in sync) and consume
        // the signal so it doesn't fire twice.
        .onChange(of: composer.pendingChildPage) { _, pending in
            guard let pending, pending.parentDocId == vm.docId else { return }
            vm.flushAllBursts()
            vm.addChildPageBlock(childDocId: pending.childDocId)
            composer.pendingChildPage = nil
        }
        .sheet(isPresented: $showingBlockPicker) {
            BlockPickerSheet { type in vm.addBlock(type: type, afterId: vm.activeBlockId) }
        }
        .alert("Error", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: { Text(vm.errorMessage ?? "") }
        // Internal-link navigation: tapping a `pinkha://doc/{uuid}` link in
        // a block pushes a fresh DocumentView onto the same NavigationStack.
        // The destination view runs through `onAppear { vm.load() }`, so the
        // target document loads from SQLite without any extra plumbing.
        .navigationDestination(item: $pushedDocId) { docId in
            DocumentView(vm: tabManager.open(docId: docId, api: vm.api), onDisappear: nil)
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
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .forEach { $0.overrideUserInterfaceStyle = style }
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

    static func lockKeyFor(docId: String) -> String { "document.locked.\(docId)" }
    static func iconKeyFor(docId: String) -> String { "document.icon.\(docId)" }
}
