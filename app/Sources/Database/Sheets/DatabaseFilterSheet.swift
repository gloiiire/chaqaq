import SwiftUI

/// Sheet to add / remove filters on the active view. The current backend
/// surface only takes property + condition ; this sheet keeps things
/// minimal (one filter per property, equals or contains). Multi-clause
/// filters land in a future PR.
struct DatabaseFilterSheet: View {
    @ObservedObject var vm: DatabaseViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAddPropertyMenu = false

    var body: some View {
        NavigationStack {
            List {
                if vm.filters.isEmpty {
                    Text("No filters. Tap + to add one.")
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(vm.filters) { filter in
                        FilterRow(filter: filter, vm: vm)
                    }
                    .onDelete { idx in
                        for i in idx { vm.removeFilter(at: i) }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.tint(.primary)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(filterableProperties) { prop in
                            Button {
                                Haptic.tap()
                                vm.addFilter(propertyId: prop.id)
                            } label: {
                                Label(prop.name, systemImage: prop.propertyType.icon)
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }

    private var filterableProperties: [PropertyFfi] {
        vm.properties.filter { prop in
            switch prop.propertyType {
            case .checkbox, .text, .number, .url, .date,
                 .selection, .selectionMultiple, .title:
                return true
            default:
                return false
            }
        }
    }
}

private struct FilterRow: View {
    let filter: DatabaseFilter
    @ObservedObject var vm: DatabaseViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: property?.propertyType.icon ?? "questionmark.circle")
                .foregroundStyle(.secondary)
            Text(property?.name ?? "—")
                .font(.body.weight(.medium))
            Spacer(minLength: 4)
            TextField("value", text: Binding(
                get: { filter.queryDraft },
                set: { vm.updateFilterValue(id: filter.id, value: $0) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 140)
        }
    }

    private var property: PropertyFfi? {
        vm.properties.first { $0.id == filter.propertyId }
    }
}
