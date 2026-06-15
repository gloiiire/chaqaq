import SwiftUI

// ── Database table view ───────────────────────────────────────────────────────
//
// Notion-inspired layout:
//   • First column is always "Name" (Title type) — the row name + doc link.
//   • Clicking the ↗ icon inside the Name cell opens DocumentView.
//   • Subsequent columns are user-defined metadata properties.
//
// Used by `DatabaseView` when the active view's type is `.table`. The
// surrounding chrome (header / toolbar / nav-title) belongs to
// `DatabaseView` — this component only renders the grid.

struct DatabaseTableView: View {
    @Bindable var vm: DatabaseViewModel
    let api: PinkhaApi
    let onDisappear: () -> Void

    @State private var showAddColumn = false

    // ── Column widths ─────────────────────────────────────────────────────────

    private func columnWidth(for type: PropertyTypeFfi) -> CGFloat {
        switch type {
        case .title:    return 240
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
                        onDisappear: onDisappear
                    )
                    Divider().padding(.leading, 8)
                }
                addRowButton
            }
            .frame(minWidth: tableWidth, alignment: .leading)
        }
        .sheet(isPresented: $showAddColumn) {
            AddColumnSheet { name, type in
                vm.addProperty(name: name, type: type)
                showAddColumn = false
            } onCancel: {
                showAddColumn = false
            }
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
                    isDeletable: !(prop.propertyType == .title),
                    sortDirection: vm.activeSort?.propertyId == prop.id
                        ? (vm.activeSort!.ascending ? .ascending : .descending)
                        : nil,
                    onRename: { vm.renameProperty(id: prop.id, newName: $0) },
                    onDelete: { vm.deleteProperty(id: prop.id) },
                    onTapSort: { vm.cycleSort(propertyId: prop.id) }
                )
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
}

// ── Column header ─────────────────────────────────────────────────────────────

private struct PropertyHeaderCell: View {
    enum SortDirection { case ascending, descending }

    @Environment(AppSettings.self) private var settings
    let name: String
    let icon: String
    let width: CGFloat
    let isDeletable: Bool
    /// `nil` = no sort on this column. Drives the arrow indicator on the
    /// right side of the cell.
    let sortDirection: SortDirection?
    let onRename: (String) -> Void
    let onDelete: () -> Void
    /// Tap on the cell body (outside the context menu / rename popover)
    /// cycles the sort on this column via the VM.
    let onTapSort: () -> Void

    @State private var showRename = false
    @State private var renameDraft = ""

    var body: some View {
        Button(action: onTapSort) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let dir = sortDirection {
                    Image(systemName: dir == .ascending
                          ? "arrow.up"
                          : "arrow.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(settings.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: 40, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            Rectangle().frame(width: 0.5).foregroundStyle(.separator)
        }
        .contextMenu {
            Button { renameDraft = name; showRename = true } label: {
                Label("Rename", systemImage: "pencil")
            }
            if isDeletable {
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label("Delete column", systemImage: "trash")
                }
            }
        }
        .alert("Rename column", isPresented: $showRename) {
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                let n = renameDraft.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { onRename(n) }
            }
            Button("Cancel", role: .cancel) {}
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
    @Environment(TabManager.self) private var tabManager

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
                    vm: tabManager.open(docId: docId, api: api),
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
            case .url:
                UrlCell(value: $value).frame(width: width)
            case .selection(let options):
                SelectionCell(value: $value, options: options).frame(width: width)
            case .selectionMultiple(let options):
                MultiSelectCell(value: $value, options: options).frame(width: width)
            case .date:
                DateCell(value: $value).frame(width: width)
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

// ── Selection / multi-select cells ────────────────────────────────────────────

private struct SelectionCell: View {
    @Binding var value: PropertyValueFfi
    let options: [String]
    @State private var showPicker = false

    private var selected: String? {
        guard case .selection(let s) = value else { return nil }
        return s
    }

    var body: some View {
        Button { showPicker = true } label: {
            HStack(spacing: 0) {
                if let s = selected { SelectionChip(label: s) } else { Color.clear }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPicker) {
            SelectionPickerSheet(options: options, selected: selected) { pick in
                value = .selection(pick)
                showPicker = false
            }
            .presentationDetents([.medium, .large])
        }
    }
}

private struct MultiSelectCell: View {
    @Binding var value: PropertyValueFfi
    let options: [String]
    @State private var showPicker = false

    private var selected: [String] {
        guard case .selectionMultiple(let s) = value else { return [] }
        return s
    }

    var body: some View {
        Button { showPicker = true } label: {
            if selected.isEmpty {
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 10)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(selected, id: \.self) { SelectionChip(label: $0) }
                    }
                    .padding(.horizontal, 10)
                }
                .frame(minHeight: 44)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPicker) {
            MultiSelectPickerSheet(options: options, selected: selected) { picks in
                value = .selectionMultiple(picks)
                showPicker = false
            }
            .presentationDetents([.medium, .large])
        }
    }
}

private struct DateCell: View {
    @Binding var value: PropertyValueFfi
    @State private var showPicker = false

    private var date: Date? {
        guard case .date(let s) = value else { return nil }
        var fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withFullDate]
        return fmt.date(from: s)
    }

    var body: some View {
        Button { showPicker = true } label: {
            Text(date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "")
                .foregroundStyle(date == nil ? .tertiary : .primary)
                .padding(.horizontal, 10)
                .frame(minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPicker) {
            DatePickerSheet(current: date) { picked in
                var fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withFullDate]
                value = picked.map { .date(fmt.string(from: $0)) } ?? .empty
                showPicker = false
            }
            .presentationDetents([.medium])
        }
    }
}

// ── Picker sheets ─────────────────────────────────────────────────────────────

private struct SelectionPickerSheet: View {
    let options: [String]
    let selected: String?
    let onSelect: (String?) -> Void

    var body: some View {
        NavigationStack {
            List {
                if selected != nil {
                    Button(role: .destructive) { onSelect(nil) } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                }
                ForEach(options, id: \.self) { opt in
                    Button {
                        onSelect(opt)
                    } label: {
                        HStack {
                            SelectionChip(label: opt)
                            Spacer()
                            if opt == selected {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Select")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onSelect(selected) }
                }
            }
        }
    }
}

private struct MultiSelectPickerSheet: View {
    let options: [String]
    let onDone: ([String]) -> Void
    @State private var current: Set<String>

    init(options: [String], selected: [String], onDone: @escaping ([String]) -> Void) {
        self.options = options
        self.onDone = onDone
        self._current = State(initialValue: Set(selected))
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(options, id: \.self) { opt in
                    Button {
                        if current.contains(opt) { current.remove(opt) } else { current.insert(opt) }
                    } label: {
                        HStack {
                            SelectionChip(label: opt)
                            Spacer()
                            if current.contains(opt) {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Select")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone(Array(current)) }
                }
            }
        }
    }
}

private struct DatePickerSheet: View {
    let onDone: (Date?) -> Void
    @State private var selected: Date
    private let hasInitial: Bool

    init(current: Date?, onDone: @escaping (Date?) -> Void) {
        self.onDone = onDone
        self.hasInitial = current != nil
        self._selected = State(initialValue: current ?? .now)
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Date", selection: $selected, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                if hasInitial {
                    Button(role: .destructive) { onDone(nil) } label: {
                        Label("Clear date", systemImage: "xmark.circle")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Pick a date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone(selected) }
                }
            }
        }
    }
}

// ── URL cell ──────────────────────────────────────────────────────────────────

private struct UrlCell: View {
    @Binding var value: PropertyValueFfi
    @State private var draft = ""
    @FocusState private var focused: Bool
    @Environment(\.openURL) private var openURL

    private var urlString: String {
        if case .url(let s) = value { return s }
        return ""
    }

    var body: some View {
        HStack(spacing: 0) {
            TextField("https://", text: $draft)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focused)
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .frame(minHeight: 44, alignment: .leading)
                .onAppear { draft = urlString }
                .onChange(of: value) { _, _ in if !focused { draft = urlString } }
                .onChange(of: focused) { _, f in
                    guard !f else { return }
                    let newVal: PropertyValueFfi = draft.isEmpty ? .empty : .url(draft)
                    if newVal != value { value = newVal }
                }

            if !urlString.isEmpty, let url = URL(string: urlString) {
                Button { openURL(url) } label: {
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
    }
}

// ── Add-column sheet ──────────────────────────────────────────────────────────

struct AddColumnSheet: View {
    let onAdd: (String, PropertyTypeFfi) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var columnType: ColumnType = .text
    @State private var options: [String] = []
    @State private var newOption = ""

    enum ColumnType: String, CaseIterable, Identifiable {
        case text = "Text"
        case number = "Number"
        case checkbox = "Checkbox"
        case date = "Date"
        case url = "URL"
        case select = "Select"
        case multiSelect = "Multi-select"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .text:        return "text.alignleft"
            case .number:      return "number"
            case .checkbox:    return "checkmark.square"
            case .date:        return "calendar"
            case .url:         return "link"
            case .select:      return "list.bullet"
            case .multiSelect: return "list.bullet.indent"
            }
        }

        var needsOptions: Bool { self == .select || self == .multiSelect }

        func propertyType(options: [String]) -> PropertyTypeFfi {
            switch self {
            case .text:        return .text
            case .number:      return .number
            case .checkbox:    return .checkbox
            case .date:        return .date
            case .url:         return .url
            case .select:      return .selection(options)
            case .multiSelect: return .selectionMultiple(options)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Column name", text: $name)
                        .submitLabel(.done)
                }
                Section("Type") {
                    Picker("Type", selection: $columnType) {
                        ForEach(ColumnType.allCases) { t in
                            Label(t.rawValue, systemImage: t.icon).tag(t)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
                if columnType.needsOptions {
                    Section {
                        ForEach(options, id: \.self) { opt in
                            HStack {
                                SelectionChip(label: opt)
                                Spacer()
                            }
                        }
                        .onDelete { options.remove(atOffsets: $0) }
                        HStack {
                            TextField("Add option…", text: $newOption)
                                .submitLabel(.done)
                                .onSubmit { Haptic.tap(); addOption() }
                            if !newOption.trimmingCharacters(in: .whitespaces).isEmpty {
                                Button(action: addOption) {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        Text("Options")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("New column")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { onCancel() } label: { Image(systemName: "xmark") }
                        .tint(.primary)
                        .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { commit() } label: { Image(systemName: "checkmark") }
                        .accessibilityLabel("Add")
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func addOption() {
        let opt = newOption.trimmingCharacters(in: .whitespaces)
        guard !opt.isEmpty, !options.contains(opt) else { return }
        options.append(opt)
        newOption = ""
    }

    private func commit() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        onAdd(n, columnType.propertyType(options: options))
    }
}

// ── Shared chip ───────────────────────────────────────────────────────────────

struct SelectionChip: View {
    let label: String

    private var color: Color {
        let palette: [Color] = [.red, .orange, .yellow, .green, .teal, .blue, .purple, .pink, .brown, .indigo]
        return palette[abs(label.hashValue) % palette.count]
    }

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .lineLimit(1)
    }
}
