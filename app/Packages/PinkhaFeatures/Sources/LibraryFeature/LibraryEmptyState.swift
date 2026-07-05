import SwiftUI

/// Placeholder shown when there are no leaves yet. `ContentUnavailableView`
/// keeps the icon size / spacing / typography aligned with the system (and
/// with `CompostView`'s empty state) without hand-tuning a VStack.
public struct LibraryEmptyState: View {
    public var body: some View {
        ContentUnavailableView(
            "No leaves",
            systemImage: "document",
            description: Text("Tap Leaf below to take your first one.")
        )
    }
}
