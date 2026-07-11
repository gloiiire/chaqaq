import SwiftUI
import PinkhaCore

// ── Tab: Inbox ────────────────────────────────────────────────────────────────

/// Inbox tab — placeholder. The bay where freshly imported items and quick
/// captures will land before being filed into shelves / books. Empty
/// state for now; the tab icon flips to `tray.badge.fill` (driven by
/// `PinkhaStore.hasInboxNotification`) when content appears here.
public struct InboxView: View {
    public init(store: PinkhaStore) {
        self.store = store
    }
    @Bindable public var store: PinkhaStore

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    InboxEmptyState()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Inbox")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

private struct InboxEmptyState: View {
    public var body: some View {
        ContentUnavailableView(
            "Inbox is empty",
            systemImage: "tray",
            description: Text("Imported items, quick captures and shared leaves will appear here.")
        )
    }
}
