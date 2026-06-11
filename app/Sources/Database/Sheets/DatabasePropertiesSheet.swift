import SwiftUI

/// Sheet to manage properties (columns) : add, rename, delete, choose
/// which one drives the active view's group-by. Mirror of the Notion
/// "Properties" panel.
struct DatabasePropertiesSheet: View {
    @ObservedObject var vm: DatabaseViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAddColumn = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(vm.properties) { prop in
                        PropertyRow(prop: prop, vm: vm)
                    }
                    .onDelete { idx in
                        for i in idx {
                            let prop = vm.properties[i]
                            if case .title = prop.propertyType { continue }
                            vm.deleteProperty(id: prop.id)
                        }
                    }
                } header: {
                    Text("Columns")
                } footer: {
                    Text("Tap a row to rename. Title can't be deleted.")
                }

                Section {
                    Picker("Group by", selection: groupByBinding) {
                        Text("None").tag(String?.none)
                        ForEach(groupableProperties) { prop in
                            Text(prop.name).tag(Optional(prop.id))
                        }
                    }
                } header: {
                    Text("Grouping")
                } footer: {
                    Text("List, Board and Gallery views are split by this property.")
                }
            }
            .navigationTitle("Properties")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.tint(.primary)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showAddColumn = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddColumn) {
                AddColumnSheet { name, type in
                    vm.addProperty(name: name, type: type)
                    showAddColumn = false
                } onCancel: { showAddColumn = false }
            }
        }
    }

    private var groupableProperties: [PropertyFfi] {
        vm.properties.filter { prop in
            switch prop.propertyType {
            case .selection, .selectionMultiple, .checkbox, .text:
                return true
            default:
                return false
            }
        }
    }

    private var groupByBinding: Binding<String?> {
        Binding(
            get: { vm.groupByPropertyId },
            set: { vm.setGroupBy(propertyId: $0) }
        )
    }
}

private struct PropertyRow: View {
    let prop: PropertyFfi
    @ObservedObject var vm: DatabaseViewModel
    @State private var showRename = false
    @State private var renameDraft = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: prop.propertyType.icon)
                .foregroundStyle(.secondary)
            Text(prop.name)
                .font(.body)
            Spacer(minLength: 4)
            if case .title = prop.propertyType {
                Text("Title")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            renameDraft = prop.name
            showRename = true
        }
        .alert("Rename column", isPresented: $showRename) {
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                let n = renameDraft.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { vm.renameProperty(id: prop.id, newName: n) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
