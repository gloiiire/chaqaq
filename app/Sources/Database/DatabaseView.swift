import SwiftUI

// ── Database table view ───────────────────────────────────────────────────────
//
// Notion-inspired layout:
//   • First column is always "Name" (Title type) — the row name + doc link.
//   • Clicking the ↗ icon inside the Name cell opens DocumentView.
//   • Subsequent columns are user-defined metadata properties.

struct DatabaseView: View {
    @StateObject private var vm: DatabaseViewModel
    let api: PinkhaApi

    @State private var showAddColumn = false
    @State private var newColumnName = ""

    init(dbId: String, api: PinkhaApi) {
        _vm  = StateObject(wrappedValue: DatabaseViewModel(dbId: dbId, api: api))
        self.api = api
    }

    // ── Column widths ─────────────────────────────────────────────────────────

    private func columnWidth(for type: PropertyTypeFfi) -> CGFloat {
        switch type {
        case .title:    return 240   // Name column — wider + space for open-doc icon
        case .text:     return 160
        case .number:   return 100
        case .checkbox: return 64
        case .date:     return 130
        case .url:      return 180
        default:        return 130
        }
    }

    private var tableWidth: CGFloat {
        vm.properties.reduce(0) { $0 + columnWidth(for: $1.propertyType) } + 48
    }

    // ── Body ──────────────────────────────────────────────────────────────────

    var body: some View {
        Group {
            if vm.properties.isEmpty && vm.entries.isEmpty {
                emptyState
            } else {
                table
            }
        }
        .navigationTitle(vm.titlePlain.isEmpty ? "Database" : vm.titlePlain)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddColumn = true } label: {
                    Label("Add column", systemImage: "plus.rectangle")
                }
            }
        }
        .sheet(isPresented: $showAddColumn, onDismiss: { newColumnName = "" }) {
            addColumnSheet
        }
        .onAppear { vm.load() }
        .errorAlert(message: $vm.errorMessage, onRetry: vm.load)
    }

    // ── Table ─────────────────────────────────────────────────────────────────

    private var table: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                Divider()
                ForEach($vm.entries) { $entry in
                    EntryRowView(
                        entry: $entry,
                        properties: vm.properties,
                        pageDocId: vm.documentId(forEntryId: entry.id),
                        api: api,
                        columnWidth: columnWidth,
                        onUpdate: { propId, value in
                            vm.updateCell(entryId: entry.id, propertyId: propId, value: value)
                        },
                        onDelete: { vm.deleteEntry(id: entry.id) },
                        onDisappear: vm.load
                    )
                    Divider().padding(.leading, 8)
                }
                addRowButton
            }
            .frame(minWidth: tableWidth, alignment: .leading)
        }
    }

    // ── Header row ────────────────────────────────────────────────────────────

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(vm.properties) { prop in
                PropertyHeaderCell(
                    name: prop.name,
                    icon: prop.propertyType.icon,
                    width: columnWidth(for: prop.propertyType),
                    isDeletable: !(prop.propertyType == .title)
                ) {
                    vm.deleteProperty(id: prop.id)
                }
            }
            // Add-column button
            Button { showAddColumn = true } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: 40)
                    .contentShape(Rectangle())
            }
        }
        .frame(height: 40)
        .background(Color(.systemGroupedBackground))
    }

    // ── Add-row button ────────────────────────────────────────────────────────

    private var addRowButton: some View {
        Button { vm.addEntry() } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.medium))
                Text("New row")
                    .font(.subheadline)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    // ── Empty state ───────────────────────────────────────────────────────────

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "tablecells")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("Empty database")
                    .font(.headline)
                Text("Add a row to create your first page.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                vm.addEntry()
            } label: {
                Label("New row", systemImage: "plus")
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // ── Add-column sheet ──────────────────────────────────────────────────────

    private var addColumnSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Column name", text: $newColumnName)
                        .submitLabel(.done)
                        .onSubmit { commitAddColumn() }
                }
            }
            .navigationTitle("New column")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { showAddColumn = false } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { commitAddColumn() } label: { Image(systemName: "checkmark") }
                        .accessibilityLabel("Add")
                        .disabled(newColumnName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func commitAddColumn() {
        let name = newColumnName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        vm.addProperty(name: name, type: .text)
        newColumnName = ""
        showAddColumn = false
    }
}

// ── Column header ─────────────────────────────────────────────────────────────

private struct PropertyHeaderCell: View {
    let name: String
    let icon: String
    let width: CGFloat
    let isDeletable: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: 40, alignment: .leading)
        .overlay(alignment: .trailing) {
            Rectangle().frame(width: 0.5).foregroundStyle(.separator)
        }
        .contextMenu {
            if isDeletable {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete column", systemImage: "trash")
                }
            }
        }
    }
}

// ── Entry row ─────────────────────────────────────────────────────────────────

private struct EntryRowView: View {
    @Binding var entry: EntryFfi
    let properties: [PropertyFfi]
    let pageDocId: String?
    let api: PinkhaApi
    let columnWidth: (PropertyTypeFfi) -> CGFloat
    let onUpdate: (String, PropertyValueFfi) -> Void
    let onDelete: () -> Void
    let onDisappear: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(properties) { prop in
                let binding = Binding<PropertyValueFfi>(
                    get: { entry.values[prop.id] ?? .empty },
                    set: { newVal in
                        entry.values[prop.id] = newVal
                        onUpdate(prop.id, newVal)
                    }
                )
                if case .title = prop.propertyType {
                    // Name/Title cell: editable name + open-doc navigation
                    TitleCell(
                        value: binding,
                        docId: pageDocId,
                        api: api,
                        width: columnWidth(.title),
                        onDisappear: onDisappear
                    )
                } else {
                    CellView(
                        value: binding,
                        propertyType: prop.propertyType,
                        width: columnWidth(prop.propertyType)
                    )
                }
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete row", systemImage: "trash")
            }
        }
    }
}

// ── Title cell (Name column) ──────────────────────────────────────────────────
// Editable row name on the left + ↗ arrow to open the linked document.

private struct TitleCell: View {
    @Binding var value: PropertyValueFfi
    let docId: String?
    let api: PinkhaApi
    let width: CGFloat
    let onDisappear: () -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            TextField("Untitled", text: $draft)
                .font(.body.weight(.medium))
                .focused($focused)
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .frame(minHeight: 44)
                .onAppear { draft = value.displayText }
                .onChange(of: value) { _, v in if !focused { draft = v.displayText } }
                .onChange(of: focused) { _, isFocused in
                    guard !isFocused else { return }
                    let spans = draft.isEmpty ? [] : [InlineTextFfi(content: draft, styles: [])]
                    let newVal = PropertyValueFfi.title(spans)
                    if newVal != value { value = newVal }
                }

            if let docId {
                NavigationLink(destination: DocumentView(
                    docId: docId,
                    api: api,
                    onDisappear: onDisappear
                )) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 44)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 36)
            }
        }
        .frame(width: width)
        .overlay(alignment: .trailing) {
            Rectangle().frame(width: 0.5).foregroundStyle(.separator)
        }
    }
}

// ── Generic cell ──────────────────────────────────────────────────────────────

private struct CellView: View {
    @Binding var value: PropertyValueFfi
    let propertyType: PropertyTypeFfi
    let width: CGFloat

    var body: some View {
        Group {
            switch propertyType {
            case .checkbox:
                CheckboxCell(value: $value).frame(width: width)
            case .text:
                TextCell(value: $value).frame(width: width)
            case .number:
                NumberCell(value: $value).frame(width: width)
            default:
                ReadOnlyCell(text: value.displayText).frame(width: width)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle().frame(width: 0.5).foregroundStyle(.separator)
        }
    }
}

// ── Cell types ────────────────────────────────────────────────────────────────

private struct CheckboxCell: View {
    @Binding var value: PropertyValueFfi
    var isOn: Bool { if case .checkbox(let b) = value { return b }; return false }

    var body: some View {
        Toggle("", isOn: Binding(get: { isOn }, set: { value = .checkbox($0) }))
            .labelsHidden()
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
    }
}

private struct TextCell: View {
    @Binding var value: PropertyValueFfi
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .focused($focused)
            .padding(.horizontal, 10)
            .frame(minHeight: 44, alignment: .leading)
            .onAppear { draft = value.displayText }
            .onChange(of: value) { _, v in if !focused { draft = v.displayText } }
            .onChange(of: focused) { _, f in
                guard !f else { return }
                let newVal = PropertyValueFfi.text(draft)
                if newVal != value { value = newVal }
            }
    }
}

private struct NumberCell: View {
    @Binding var value: PropertyValueFfi
    @State private var draft = ""
    @FocusState private var focused: Bool
    private var num: Double? { if case .number(let n) = value { return n }; return nil }

    var body: some View {
        TextField("", text: $draft)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .padding(.horizontal, 10)
            .frame(minHeight: 44, alignment: .leading)
            .onAppear { draft = num.map { $0.formatted() } ?? "" }
            .onChange(of: value) { _, _ in if !focused { draft = num.map { $0.formatted() } ?? "" } }
            .onChange(of: focused) { _, f in
                guard !f else { return }
                if draft.isEmpty { if value != .empty { value = .empty } }
                else if let n = Double(draft) { let v = PropertyValueFfi.number(n); if v != value { value = v } }
            }
    }
}

private struct ReadOnlyCell: View {
    let text: String
    var body: some View {
        Text(text.isEmpty ? "—" : text)
            .foregroundStyle(text.isEmpty ? .tertiary : .primary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minHeight: 44, alignment: .leading)
    }
}
