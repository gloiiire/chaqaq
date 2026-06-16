import SwiftUI
import PinkhaFFI
import PinkhaCore
import LeafFeature

/// Kanban-style horizontally scrolling board. Each column is a value
/// of the `groupBy` property ; entries with that value stack vertically
/// as cards inside the column. Notion's "Board view".
public struct BookBoardView: View {
    @Bindable var vm: BookViewModel
    let api: PinkhaApi
    let onDisappear: () -> Void

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(vm.groupedRows, id: \.title) { group in
                    BoardColumn(
                        title: group.title,
                        entries: group.entries,
                        vm: vm,
                        api: api,
                        onDisappear: onDisappear
                    )
                    .frame(width: 280)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .background(Color(.systemGroupedBackground))
    }
}

private struct BoardColumn: View {
    let title: String
    let entries: [EntryFfi]
    let vm: BookViewModel
    let api: PinkhaApi
    let onDisappear: () -> Void

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title.isEmpty ? "Untitled" : title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                Text("\(entries.count)")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 4)

            ForEach(entries) { entry in
                BoardCard(
                    entry: entry,
                    properties: vm.properties,
                    icon: vm.iconForEntry(entry),
                    leafId: vm.leafId(forEntryId: entry.id),
                    api: api,
                    onDisappear: onDisappear
                )
            }

            Button {
                Haptic.tap()
                vm.addEntry(forGroup: title)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("Add card")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemBackground),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}

private struct BoardCard: View {
    let entry: EntryFfi
    let properties: [PropertyFfi]
    let icon: String?
    let leafId: String?
    let api: PinkhaApi
    let onDisappear: () -> Void

    @Environment(TabManager.self) private var tabManager

    public var body: some View {
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let icon, !icon.isEmpty {
                    Text(icon).font(.title3)
                }
                Text(titleText.isEmpty ? "Untitled" : titleText)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.systemBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var titleText: String {
        guard let p = properties.first(where: {
            if case .title = $0.propertyType { return true }; return false
        }) else { return "" }
        return entry.values[p.id]?.displayText ?? ""
    }
}
