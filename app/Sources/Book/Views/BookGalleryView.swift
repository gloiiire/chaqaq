import SwiftUI
import PinkhaFFI
import LeafFeature

/// Card-grid layout. Each entry renders as a large tile with the
/// linked leaf's cover (or a colored placeholder), title and the
/// first multi-select chip. Notion's "Gallery view" — mobile-friendly
/// because cards reflow into a 2-column grid below the breakpoint.
struct BookGalleryView: View {
    @Bindable var vm: BookViewModel
    let api: PinkhaApi
    let onDisappear: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass

    private var columns: [GridItem] {
        let count = sizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 14), count: count)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(vm.filteredEntries) { entry in
                GalleryCard(
                    entry: entry,
                    properties: vm.properties,
                    icon: vm.iconForEntry(entry),
                    leafId: vm.leafId(forEntryId: entry.id),
                    api: api,
                    onDisappear: onDisappear
                )
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 80)
    }
}

private struct GalleryCard: View {
    let entry: EntryFfi
    let properties: [PropertyFfi]
    let icon: String?
    let leafId: String?
    let api: PinkhaApi
    let onDisappear: () -> Void

    @Environment(TabManager.self) private var tabManager

    var body: some View {
        Group {
            if let leafId {
                NavigationLink(destination: LeafView(
                    vm: tabManager.open(leafId: leafId, api: api),
                    onDisappear: onDisappear
                )) { card }.buttonStyle(.plain)
            } else { card }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Placeholder gradient cover — replaced by the linked
            // leaf's cover image once a doc-cover-fetch helper
            // lands on the VM (TODO : follow-up PR).
            LinearGradient(
                colors: [Color.secondary.opacity(0.12), Color.secondary.opacity(0.22)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topLeading) {
                if let icon, !icon.isEmpty {
                    Text(icon).font(.title2).padding(8)
                }
            }

            Text(titleText.isEmpty ? "Untitled" : titleText)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color(.systemBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var titleText: String {
        guard let p = properties.first(where: {
            if case .title = $0.propertyType { return true }; return false
        }) else { return "" }
        return entry.values[p.id]?.displayText ?? ""
    }
}
