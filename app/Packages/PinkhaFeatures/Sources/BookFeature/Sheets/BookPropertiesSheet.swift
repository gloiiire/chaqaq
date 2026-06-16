import SwiftUI
import PinkhaFFI

/// Sheet to manage properties (columns) : add, rename, delete, choose
/// which one drives the active view's group-by. Mirror of the Notion
/// "Properties" panel.
public struct BookPropertiesSheet: View {
    @Bindable var vm: BookViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAddColumn = false

    public var body: some View {
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

                if !dateProperties.isEmpty {
                    Section {
                        Picker("Source column", selection: publishedAtSourceBinding) {
                            Text("None").tag(String?.none)
                            ForEach(dateProperties) { prop in
                                Text(prop.name).tag(Optional(prop.id))
                            }
                        }
                    } header: {
                        Text("Publish date")
                    } footer: {
                        Text("Rows take their publish date from this date column — sorting by Published follows it, and editing a date re-dates the row. None: publish dates follow the creation date.")
                    }
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
            .scrollDismissesKeyboard(.interactively)
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

    private var dateProperties: [PropertyFfi] {
        vm.properties.filter { prop in
            if case .date = prop.propertyType { return true }
            return false
        }
    }

    private var publishedAtSourceBinding: Binding<String?> {
        Binding(
            get: { vm.publishedAtSource },
            set: { vm.setPublishedAtSource(propertyId: $0) }
        )
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
    @Bindable var vm: BookViewModel
    @State private var showRename = false
    @State private var renameDraft = ""

    public var body: some View {
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
