import SwiftUI
import PinkhaCore

// ── Tab: Inbox ────────────────────────────────────────────────────────────────

/// Inbox tab — placeholder. The bay where freshly imported items and quick
/// captures will land before being filed into folders / databases. Empty
/// state for now; the tab icon flips to `tray.badge.fill` (driven by
/// `PinkhaStore.hasInboxNotification`) when content appears here.
struct InboxView: View {
    @Bindable var store: PinkhaStore

    var body: some View {
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
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("Inbox is empty").font(.headline)
                Text("Imported items, quick captures and shared notes\nwill appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
