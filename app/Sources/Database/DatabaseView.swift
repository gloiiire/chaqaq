import SwiftUI

// ── Database view ─────────────────────────────────────────────────────────────

/// Full table view for a Pinkha database — properties as columns, entries as rows.
/// Each row is a linked document: tapping the page icon opens DocumentView.
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

    private let pageColumnWidth: CGFloat = 44

    private func columnWidth(for type: PropertyTypeFfi) -> CGFloat {
        switch type {
        case .title:    return 220
        case .text:     return 160
        case .number:   return 100
        case .checkbox: return 64
        case .date:     return 130
        case .url:      return 180
        default:        return 130
        }
    }

    private var tableWidth: CGFloat {
        let cols = vm.properties.reduce(0) { $0 + columnWidth(for: $1.propertyType) }
        return pageColumnWidth + cols + 48 // page col + property cols + add-column button
    }

    // ── Body ──────────────────────────────────────────────────────────────────

    var body: some View {
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
                        pageColumnWidth: pageColumnWidth,
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

    // ── Header row ────────────────────────────────────────────────────────────

    private var headerRow: some View {
        HStack(spacing: 0) {
            // Page-link column header (empty — icon communicates purpose)
            Color.clear
                .frame(width: pageColumnWidth, height: 40)
                .overlay(alignment: .trailing) {
                    Rectangle().frame(width: 0.5).foregroundStyle(.separator)
                }

            ForEach(vm.properties) { prop in
                PropertyHeaderCell(name: prop.name, icon: prop.propertyType.icon,
                                   width: columnWidth(for: prop.propertyType))
                .contextMenu {
                    Button(role: .destructive) { vm.deleteProperty(id: prop.id) } label: {
                        Label("Delete column", systemImage: "trash")
                    }
                }
            }
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

// ── Property column header ────────────────────────────────────────────────────

private struct PropertyHeaderCell: View {
    let name: String
    let icon: String
    let width: CGFloat

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
    }
}

// ── Entry row ─────────────────────────────────────────────────────────────────

private struct EntryRowView: View {
    @Binding var entry: EntryFfi
    let properties: [PropertyFfi]
    let pageDocId: String?
    let api: PinkhaApi
    let pageColumnWidth: CGFloat
    let columnWidth: (PropertyTypeFfi) -> CGFloat
    let onUpdate: (String, PropertyValueFfi) -> Void
    let onDelete: () -> Void
    let onDisappear: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Page-open button
            pageButton
                .frame(width: pageColumnWidth)
                .overlay(alignment: .trailing) {
                    Rectangle().frame(width: 0.5).foregroundStyle(.separator)
                }

            // Property cells
            ForEach(properties) { prop in
                CellView(
                    value: Binding(
                        get: { entry.values[prop.id] ?? .empty },
                        set: { newVal in
                            entry.values[prop.id] = newVal
                            onUpdate(prop.id, newVal)
                        }
                    ),
                    propertyType: prop.propertyType,
                    width: columnWidth(prop.propertyType)
                )
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

    @ViewBuilder
    private var pageButton: some View {
        if let docId = pageDocId {
            NavigationLink(destination: DocumentView(
                docId: docId,
                api: api,
                onDisappear: onDisappear
            )) {
                Image(systemName: "doc.text")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: pageColumnWidth, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Image(systemName: "doc.text")
                .font(.body)
                .foregroundStyle(.tertiary)
                .frame(width: pageColumnWidth, height: 44)
        }
    }
}

// ── Cell view ─────────────────────────────────────────────────────────────────

private struct CellView: View {
    @Binding var value: PropertyValueFfi
    let propertyType: PropertyTypeFfi
    let width: CGFloat

    var body: some View {
        Group {
            switch propertyType {
            case .checkbox:
                CheckboxCell(value: $value).frame(width: width)
            case .title, .text:
                TextCell(value: $value, isTitle: propertyType == .title).frame(width: width)
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

    var isOn: Bool {
        if case .checkbox(let b) = value { return b }
        return false
    }

    var body: some View {
        Toggle("", isOn: Binding(
            get: { isOn },
            set: { value = .checkbox($0) }
        ))
        .labelsHidden()
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
    }
}

private struct TextCell: View {
    @Binding var value: PropertyValueFfi
    let isTitle: Bool

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .font(isTitle ? .body.weight(.medium) : .body)
            .focused($focused)
            .padding(.horizontal, 10)
            .frame(minHeight: 44, alignment: .leading)
            .onAppear { draft = value.displayText }
            .onChange(of: value) { _, newVal in
                if !focused { draft = newVal.displayText }
            }
            .onChange(of: focused) { _, isFocused in
                guard !isFocused else { return }
                let newValue: PropertyValueFfi = isTitle
                    ? .title([InlineTextFfi(content: draft, styles: [])])
                    : .text(draft)
                if newValue != value { value = newValue }
            }
    }
}

private struct NumberCell: View {
    @Binding var value: PropertyValueFfi

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    private var currentNumber: Double? {
        if case .number(let n) = value { return n }
        return nil
    }

    var body: some View {
        TextField("", text: $draft)
            .keyboardType(.decimalPad)
            .focused($focused)
            .padding(.horizontal, 10)
            .frame(minHeight: 44, alignment: .leading)
            .multilineTextAlignment(.trailing)
            .onAppear { draft = currentNumber.map { $0.formatted() } ?? "" }
            .onChange(of: value) { _, _ in
                if !focused { draft = currentNumber.map { $0.formatted() } ?? "" }
            }
            .onChange(of: focused) { _, isFocused in
                guard !isFocused else { return }
                if draft.isEmpty {
                    if value != .empty { value = .empty }
                } else if let n = Double(draft) {
                    let newVal = PropertyValueFfi.number(n)
                    if newVal != value { value = newVal }
                }
            }
    }
}

private struct ReadOnlyCell: View {
    let text: String

    var body: some View {
        Text(text.isEmpty ? "—" : text)
            .font(.body)
            .foregroundStyle(text.isEmpty ? .tertiary : .primary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minHeight: 44, alignment: .leading)
    }
}
