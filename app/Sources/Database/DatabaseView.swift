import SwiftUI

/// Orchestrates the full database screen :
///   1. Scrollable doc-like header (cover + icon + title + description).
///   2. Sticky toolbar (view picker / search / filter / properties / +).
///   3. Active body component picked by the active view's `ViewTypeFfi`.
///
/// The chrome (nav title, back chevron, error alert) lives here ;
/// the body components only render rows/cards/calendars/etc.
struct DatabaseView: View {
    @StateObject private var vm: DatabaseViewModel
    let api: PinkhaApi
    var onDisappear: (() -> Void)? = nil

    @State private var searchVisible = false
    @State private var recentEmojis: [String] = []

    init(dbId: String, api: PinkhaApi, onDisappear: (() -> Void)? = nil) {
        _vm = StateObject(wrappedValue: DatabaseViewModel(dbId: dbId, api: api))
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
        .navigationTitle(vm.titlePlain.isEmpty ? Text("Database") : Text(vm.titlePlain))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { vm.load() }
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
