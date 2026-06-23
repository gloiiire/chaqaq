import SwiftUI

/// Placeholder shown when there are no leaves yet.
public struct LibraryEmptyState: View {
    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "document")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("No leaves").font(.headline)
                Text("Tap Leaf below to take your first one.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
