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
    @Environment(AmbientLight.self) var ambientLight
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
    /// Drives the flush-on-background below.
    @Environment(\.scenePhase) var scenePhase
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
    /// PRO-62 : "Themes & settings" sheet (text size + theme grid +
    /// brightness + customize theme sub-sheet). Triggered from the
    /// overflow menu's "Themes & settings" row.
    @State var showingReaderSettingsSheet = false
    /// Local per-leaf typography state — temporary in-memory storage
    /// until the corresponding Rust `Leaf` fields ship. Lifted here
    /// so the sheet can bind to it directly via `$readerFontScale`
    /// etc., and the values persist across re-opens of the sheet
    /// within the same leaf session.
    /// Local mirror of the system brightness so SwiftUI's Slider has a
    /// reactive source to bind to (UIScreen.main.brightness isn't
    /// `@Observable` ; binding the slider directly to it left the
    /// thumb stuck because get() returned a non-observed value).
    /// `onChange(of:)` writes the value back to `UIScreen.brightness`
    /// in real time as the user drags.
    @State var readerBrightness: Double = Double(UIScreen.main.brightness)
    /// Snapshot of the system screen brightness captured the moment
    /// the reader-settings sheet appears. Restored on dismiss so a
    /// notes app doesn't permanently dim the user's device (Apple
    /// Books does NOT restore — we diverge here intentionally).
    @State var originalScreenBrightness: CGFloat? = nil
    /// PRO-62 : presents the "Personnaliser le thème" sub-sheet on
    /// top of the main reader settings sheet.
    @State var showingCustomizeThemeSheet = false

    // PRO-62 — typography state is now persisted on the leaf via
    // `vm.readerSettings`. The sheet binds directly to that bundle ;
    // no more SwiftUI-local mirrors that get lost on dismiss.
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
                              themeForeground: effectiveTheme.effectiveForegroundColor(darkVariant: effectiveThemeDarkVariant).map(UIColor.init),
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
            // `.listRowSeparator(.hidden)` est répété ICI alors que
            // `blockListRow` l'applique déjà — et ce n'est pas redondant.
            //
            // Sur iOS 27, `.reorderable()` réintroduit les séparateurs de
            // rangée : un trait apparaît entre chaque bloc, ce qui donne
            // l'illusion qu'un Divider a été inséré à chaque retour à la
            // ligne. Ce n'est pas le cas — `onNewBlock` ne crée que des
            // blocs texte. Le masquage posé à l'intérieur de la rangée
            // ne survit pas au modificateur ; posé sur le `ForEach`, si.
            //
            // Le bug n'apparaît que sur iOS 27, la branche `.onMove`
            // d'iOS 26 n'ayant jamais eu le problème.
            if #available(iOS 27.0, *) {
                ForEach($vm.blocks) { $block in blockListRow($block) }
                    .reorderable()
                    .listRowSeparator(.hidden)
            } else {
                ForEach($vm.blocks) { $block in blockListRow($block) }
                    .onMove(perform: vm.moveBlock)
                    .listRowSeparator(.hidden)
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
            // Zone morte 40–60 pt, indispensable et non cosmétique.
            //
            // La grandeur comparée inclut `contentInsets.top` — et la
            // réaction la modifie : afficher le titre dans la barre, plus
            // `LeafNavBarMinimizationModifier` qui la redimensionne,
            // changent cet inset. Avec un seuil unique, se garer dessus
            // suffit à faire osciller le drapeau : chaque bascule déplace
            // l'inset, donc la mesure, donc rebascule.
            //
            // Hors transition ça s'amortit, chaque bascule attendant
            // l'image suivante. Pendant une transition d'onglet, tout est
            // enfermé dans un `layoutBelowIfNeeded` SYNCHRONE : plus de
            // frontière d'image, la boucle tourne sur place. Le profil
            // d'un gel réel montre exactement ce cycle —
            // `_updateSafeAreaInsets` → `UIScrollView.setSafeAreaInsets:`
            // → `_notifyDidScroll` → l'observateur de défilement de
            // SwiftUI → mise en page → et on recommence.
            //
            // Deux seuils rendent l'oscillation impossible : sortir
            // demande de traverser 20 pt, ce qu'un changement d'inset ne
            // produit jamais.
            let shouldShow = titleShouldEnterNavBar(offset: offset, currently: titleInNavBar)
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
        .background(effectiveTheme.effectiveBackgroundColor(darkVariant: effectiveThemeDarkVariant)
                    ?? Color.pinkhaSurface(dark: effectiveThemeDarkVariant))
        .preferredColorScheme(effectiveTheme.effectiveColorScheme(darkVariant: effectiveThemeDarkVariant))
        // Make the active reader theme available to every block row so
        // they pick up the theme's font family (Georgia / Charter /
        // Palatino / Avenir Next / system). Mirrors Apple Books.
        .environment(\.readerTheme, effectiveTheme)
        // Same for the font-scale stepper — every block row multiplies
        // its base point size by this scalar so the A−/A+ buttons
        // affect the actual rendered text live. Sourced from the
        // persisted `vm.readerSettings.fontScale` so the chosen value
        // survives leaf reopen / app relaunch.
        .environment(\.readerFontScale, vm.readerSettings.fontScale)
        // PRO-62 : typography overrides (line / letter / word
        // spacing + justify + bold + margin scale) propagated to
        // every block row. The four spacing values only take effect
        // when `customLayoutEnabled` is true ; bold + margin apply
        // unconditionally so the user can flip them in isolation.
        .environment(\.readerTypography, ReaderTypographyOverrides(
            bold: vm.readerSettings.bold,
            lineSpacingMultiple: vm.readerSettings.lineSpacing,
            letterSpacing: vm.readerSettings.letterSpacing,
            wordSpacing: vm.readerSettings.wordSpacing,
            marginScale: vm.readerSettings.marginScale,
            justify: vm.readerSettings.justify,
            customLayoutEnabled: vm.readerSettings.customLayoutEnabled,
            fontFamily: vm.readerSettings.fontFamily
        ))
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
        .onChange(of: effectiveTheme) { _, _ in
            syncWindowTheme()
            publishLeafColorScheme()
        }
        // Re-sync the window appearance when the user flips the
        // sun/moon toggle in the reader settings sheet — the leaf
        // bg/fg + keyboard appearance need to flip too.
        .onChange(of: effectiveThemeDarkVariant) { _, _ in
            syncWindowTheme()
            publishLeafColorScheme()
        }
        .onAppear {
            syncWindowTheme()
            publishLeafColorScheme()
            // Ouvre directement la sheet de personnalisation. Le menu de
            // débordement est un `UIMenu` UIKit, que `ImportUITests`
            // documente comme non automatisable de façon fiable sur
            // simulateur : sans ce raccourci, la sheet n'est atteignable
            // par aucun test ni aucune capture automatisée, et sa parité
            // avec Books ne peut être vérifiée que de mémoire.
            // Même famille que `--ui-test-data` / `--ui-test-clean`.
            if ProcessInfo.processInfo.arguments.contains("--ui-test-reader-customize") {
                showingReaderSettingsSheet = true
                showingCustomizeThemeSheet = true
            }
        }
        .onDisappear {
            // Clear the leaf-scoped scheme so the TabView's
            // `.preferredColorScheme` falls back to the global app
            // appearance once the user navigates back to a tab root.
            readerMode.activeLeafColorScheme = nil
        }
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
        // Typing is persisted lazily: block edits land 300 ms after the last
        // keystroke (`saveBlock`'s burst debounce) and the title only on
        // end-editing. `onDisappear` flushes both — but it does NOT fire
        // when the app is backgrounded, so force-quitting from the app
        // switcher (or a jetsam kill) while the title field is focused lost
        // the entire title, plus the trailing burst of body typing.
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            vm.flushAllBursts()
            vm.saveTitle()
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
        .sheet(isPresented: $showingReaderSettingsSheet, onDismiss: {
            // Restore system brightness so a notes app doesn't leave
            // the screen permanently dimmed after the user dismisses.
            // Same scene-based write as the slider's `onChange` — the
            // legacy `UIScreen.main.brightness =` setter is a silent
            // no-op on some iOS 26 scene configs.
            if let original = originalScreenBrightness {
                let scene = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .first { $0.activationState == .foregroundActive }
                    ?? UIApplication.shared.connectedScenes
                        .compactMap { $0 as? UIWindowScene }
                        .first
                scene?.screen.brightness = original
                originalScreenBrightness = nil
            }
        }) {
            ReaderSettingsSheet(
                theme: Binding(
                    get: { vm.theme },
                    set: { newRaw in
                        vm.saveTheme(newRaw)
                        // Apple Books pattern : selecting a theme loads
                        // its full factory defaults (line spacing +
                        // bold + justify + Personnaliser toggle). The
                        // user can still override via the customize
                        // sheet afterwards.
                        let theme = newRaw.flatMap { AppSettings.Theme(rawValue: $0) }
                                    ?? settings.theme
                        var s = vm.readerSettings
                        s.lineSpacing = theme.defaultLineSpacing
                        s.bold = theme.defaultBold
                        s.justify = theme.defaultJustify
                        s.customLayoutEnabled = theme.defaultCustomLayoutEnabled
                        vm.saveReaderSettings(s)
                    }
                ),
                fontScale: Binding(
                    get: { vm.readerSettings.fontScale },
                    set: { newValue in
                        var s = vm.readerSettings
                        s.fontScale = newValue
                        vm.saveReaderSettings(s)
                    }
                ),
                // Slider binds to the @State mirror so SwiftUI gets a
                // reactive value to drive the thumb ; the .onChange
                // below pushes every update to UIScreen.brightness
                // in real time.
                brightness: $readerBrightness,
                appearance: Binding(
                    get: { ReaderAppearance.parse(vm.readerSettings.themeAppearance) },
                    set: { newMode in
                        var s = vm.readerSettings
                        s.themeAppearance = newMode.rawValue
                        // Mirror the resolved bool onto the legacy
                        // field so an older app version reading this
                        // row still sees a sensible value (and so any
                        // call site we haven't migrated yet keeps
                        // returning the right answer).
                        s.themeDarkVariant = newMode.effectiveDark(
                            systemIsDark: deviceIsDark,
                            settingsIsDark: appWideIsDark,
                            ambientIsDark: ambientIsDark
                        )
                        vm.saveReaderSettings(s)
                    }
                ),
                systemIsDark: deviceIsDark,
                settingsIsDark: appWideIsDark,
                ambientIsDark: ambientIsDark,
                themeOptions: ReaderThemeOption.all,
                onPersonnaliser: {
                    showingCustomizeThemeSheet = true
                },
                onClose: { showingReaderSettingsSheet = false }
            )
            // Apple Books pins the reader settings sheet at ~62 % of
            // screen height (re-measured pixel-by-pixel 2026-06-26).
            // Drag indicator IS visible in Apple Books — the X close
            // button is the affordance for tap-to-dismiss, the grabber
            // is the affordance for swipe-to-dismiss (we used to hide
            // it ; that diverged from Books).
            .presentationDetents([.fraction(0.62)])
            .presentationDragIndicator(.visible)
            // Force the sheet to inherit the leaf's resolved color
            // scheme. Sheets are presented in their own UIKit hosting
            // window, which doesn't pick up the presenter's
            // `.preferredColorScheme(...)` modifier — without this
            // the sheet renders in the GLOBAL app appearance even
            // when the leaf is in a dark Books theme.
            .preferredColorScheme(
                effectiveTheme.effectiveColorScheme(
                    darkVariant: effectiveThemeDarkVariant
                )
            )
            // Liquid Glass : iOS 26 sheets ride on a translucent
            // material by default ONLY when their content background
            // is non-opaque. The sheet's inner VStacks now use
            // translucent fills, so the thin material requested here
            // shows through. `.thinMaterial` matches the Apple Books
            // reader settings sheet density.
            .presentationBackground(.thinMaterial)
            .onAppear {
                // Snapshot the current brightness for restore-on-dismiss.
                originalScreenBrightness = UIScreen.main.brightness
                // Sync the @State mirror with the actual system value
                // (in case it changed since the leaf opened).
                readerBrightness = Double(UIScreen.main.brightness)
                // No more dark-variant auto-seed here : the new
                // appearance enum defaults to `.settings`, which
                // already pulls from the app-wide toggle. Forcing
                // `dark` when the system is dark would silently
                // upgrade legacy `.settings` leaves into per-leaf
                // overrides and prevent them from following the
                // global preference afterwards.
            }
            .onChange(of: readerBrightness) { _, newValue in
                // Push slider drags onto the actual screen brightness.
                //
                // `UIScreen.main` is soft-deprecated on iOS 16+ and on
                // some scene configurations the legacy setter is
                // silently ignored (the read still works but the write
                // is a no-op). Walk through the active `UIWindowScene`
                // instead — this is the modern path and is the only
                // one that reliably mutates brightness on iOS 26.
                //
                // SIMULATOR CAVEAT : the simulator has no backlight,
                // so brightness writes appear to no-op even with this
                // path. The slider works on a real device.
                let scene = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .first { $0.activationState == .foregroundActive }
                    ?? UIApplication.shared.connectedScenes
                        .compactMap { $0 as? UIWindowScene }
                        .first
                scene?.screen.brightness = CGFloat(newValue)
            }
            // PRO-62 step 9 : customize-theme sub-sheet stacked on
            // top of the main settings sheet. Bindings flow through
            // `vm.readerSettings` so changes persist on the leaf.
            .sheet(isPresented: $showingCustomizeThemeSheet) {
                ReaderThemeCustomizationSheet(
                    fontFamily: Binding(
                        get: { vm.readerSettings.fontFamily ?? "System" },
                        set: { newValue in
                            var s = vm.readerSettings
                            s.fontFamily = newValue == "System" ? nil : newValue
                            vm.saveReaderSettings(s)
                        }
                    ),
                    bold:               readerSettingsBinding(\.bold),
                    lineSpacing:        readerSettingsBinding(\.lineSpacing),
                    letterSpacing:      readerSettingsBinding(\.letterSpacing),
                    wordSpacing:        readerSettingsBinding(\.wordSpacing),
                    marginScale:        readerSettingsBinding(\.marginScale),
                    justify:            readerSettingsBinding(\.justify),
                    customLayoutEnabled: readerSettingsBinding(\.customLayoutEnabled),
                    leafPreviewText: leafPreviewSnippet(),
                    // Apple Books pattern : the Reset action is
                    // disabled when the user hasn't deviated from the
                    // theme's factory defaults. We compare every
                    // typography field to the theme baseline ; the
                    // font_scale + font_family overrides also flag
                    // the leaf as dirty since they survive theme
                    // changes.
                    canReset: !isAtThemeFactoryDefaults,
                    // Theme palette mirroring the live leaf — preview
                    // surface uses the same bg / fg the user will
                    // actually see once they commit.
                    previewBackground: effectiveTheme.effectiveBackgroundColor(
                        darkVariant: effectiveThemeDarkVariant
                    ) ?? Color(uiColor: .systemBackground),
                    previewForeground: effectiveTheme.effectiveForegroundColor(
                        darkVariant: effectiveThemeDarkVariant
                    ) ?? Color(uiColor: .label),
                    // Falls back the preview's font to the active
                    // theme's family when the user hasn't picked a
                    // custom one (picker shows "System").
                    themeFontFamily: effectiveTheme.fontFamily,
                    themeFontDisplayName: effectiveTheme.fontDisplayName,
                    onCommit: { showingCustomizeThemeSheet = false },
                    onDiscard: { showingCustomizeThemeSheet = false },
                    onReset: {
                        // Apple Books pattern : Reset reverts the
                        // leaf to the ACTIVE THEME's factory defaults,
                        // not to generic LeafReaderSettings defaults.
                        // The Personnaliser toggle stays ON for every
                        // theme except Original (theme baseline
                        // already includes typography overrides).
                        let t = effectiveTheme
                        var s = LeafReaderSettings()
                        s.lineSpacing = t.defaultLineSpacing
                        s.bold = t.defaultBold
                        s.justify = t.defaultJustify
                        s.customLayoutEnabled = t.defaultCustomLayoutEnabled
                        // Preserve both the legacy bool AND the new
                        // 5-way appearance choice so a Reset doesn't
                        // silently flip the user's per-leaf light/dark
                        // override back to factory.
                        s.themeDarkVariant = vm.readerSettings.themeDarkVariant
                        s.themeAppearance = vm.readerSettings.themeAppearance
                        vm.saveReaderSettings(s)
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
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
        switch effectiveTheme.effectiveColorScheme(darkVariant: effectiveThemeDarkVariant) {
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

    /// Publishes the leaf's effective `ColorScheme` to the shared
    /// `ReaderMode` so `ContentView` can mirror it onto the TabView
    /// via `.preferredColorScheme`. Without this, the bottom-accessory
    /// bar (CreateBubble) lives in the parent's SwiftUI environment
    /// and its `.primary` foregrounds resolve to the GLOBAL color
    /// scheme — yielding dark icons on dark glass when the app is in
    /// light mode and the leaf is in a dark theme.
    func publishLeafColorScheme() {
        let darkVariant = effectiveThemeDarkVariant
        let scheme = effectiveTheme.effectiveColorScheme(darkVariant: darkVariant)
        // For `.original` (no theme override), publish nil so the tab
        // bar follows the global appearance — not a synthesised value
        // from the dark-variant toggle alone.
        readerMode.activeLeafColorScheme = scheme
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
