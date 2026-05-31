import SwiftUI

// ── Database view (placeholder) ───────────────────────────────────────────────

/// Placeholder shown when opening a database — UI coming soon.
struct DatabasePlaceholderView: View {
    let title: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "tablecells")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text(title.isEmpty ? "Untitled" : title)
                    .font(.headline)
                Text("Database view coming soon.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(title.isEmpty ? "Untitled" : title)
        .navigationBarTitleDisplayMode(.large)
    }
}
