import SwiftUI
import PinkhaFFI
import PinkhaCore
import PinkhaDesignSystem

/// Orchestrates the full database screen :
///   1. Scrollable doc-like header (cover + icon + title + description).
///   2. Sticky toolbar (view picker / search / filter / properties / +).
///   3. Active body component picked by the active view's `ViewTypeFfi`.
///
/// The chrome (nav title, back chevron, error alert) lives here ;
/// the body components only render rows/cards/calendars/etc.
struct DatabaseView: View {
    @State private var vm: DatabaseViewModel
    let api: PinkhaApi
    var onDisappear: (() -> Void)? = nil

    @Environment(AppSettings.self) private var settings
    @Environment(TabManager.self) private var tabManager
    @State private var searchVisible = false
    @State private var recentEmojis: [String] = []

    init(dbId: String, api: PinkhaApi, onDisappear: (() -> Void)? = nil) {
        _vm = State(wrappedValue: DatabaseViewModel(dbId: dbId, api: api))
        self.api = api
        self.onDisappear = onDisappear
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                DatabaseHeaderView(vm: vm, recentEmojis: recentEmojis)
                Section {
                    body(for: vm.activeView?.type ?? .list)
                } header: {
                    DatabaseToolbarView(vm: vm, searchVisible: $searchVisible)
                        .background(.bar)
                }
            }
        }
        // Dim base behind the cards so each row's
        // `.secondarySystemGroupedBackground` reads as elevated,
        // matching the inset-grouped vocabulary of `WorkspaceView`.
        .background(Color(.systemGroupedBackground))
        .scrollContentBackground(.hidden)
        // Mirror the document treatment : when a cover is present, let
        // the scroll content extend behind the status bar / nav-bar so
        // the cover bleeds edge-to-edge to the top of the screen and
        // the nav controls float on glass over the image. Falls back
        // to a normal inset layout when there's no cover.
        .ignoresSafeArea(.container, edges: vm.cover == nil ? [] : .top)
        // Empty nav-title — the H1 lives inside the doc-like header,
        // matching the document behaviour. The back button + any
        // overflow stays available in the toolbar slot.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // Adaptive glass background re-vibrancies the nav-bar over
        // whatever surface scrolls beneath it (cover image vs body).
        .toolbarBackground(.automatic, for: .navigationBar)
        // Lock toggle lives in the nav-bar trailing slot — same
        // surface as the document lock so users get the same gesture
        // pattern end-to-end. iOS 26 visually groups it with the back
        // chevron into the glass capsule.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                LockToolbarButton(
                    locked: vm.locked,
                    accent: settings.accentColor
                ) {
                    Haptic.toggle()
                    vm.toggleLock()
                }
            }
        }
        .onAppear {
            vm.load()
            // Track the open so the Notes home Recent strip surfaces
            // recently-visited databases alongside docs. MRU-only push
            // — no phantom document tab is created, the DB stays
            // identifiable as a database in `WorkspaceItem`.
            tabManager.markRecentlyViewed(id: vm.dbId)
        }
        .onDisappear { onDisappear?() }
        .errorAlert(message: $vm.errorMessage, onRetry: vm.load)
    }

    @ViewBuilder
    private func body(for type: ViewTypeFfi) -> some View {
        switch type {
        case .list:
            DatabaseListView(vm: vm, api: api, onDisappear: vm.load)
        case .table:
            DatabaseTableView(vm: vm, api: api, onDisappear: vm.load)
                .frame(minHeight: 400)
        case .kanban:
            DatabaseBoardView(vm: vm, api: api, onDisappear: vm.load)
        case .calendar:
            DatabaseCalendarView(vm: vm, api: api, onDisappear: vm.load)
        case .gallery:
            DatabaseGalleryView(vm: vm, api: api, onDisappear: vm.load)
        }
    }
}
