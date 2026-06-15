import SwiftUI


/// Inline editor for a single property — picked based on the property
/// type. Mirrors the cell widgets used by DatabaseTableView in spirit,
/// but is self-contained so the sheet doesn't reach across the
/// database internals.
struct PropertyInputRow: View {
    let property: PropertyFfi
    @Binding var value: PropertyValueFfi

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: property.propertyType.icon)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(property.name)
                    .font(.subheadline.weight(.medium))
                editor
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch property.propertyType {
        case .text:
            TextField("Text", text: textBinding(get: {
                if case .text(let s) = value { return s }; return ""
            }, set: { value = $0.isEmpty ? .empty : .text($0) }))
                .textFieldStyle(.plain)
        case .number:
            TextField("Number", text: textBinding(get: {
                if case .number(let n) = value { return n.formatted() }; return ""
            }, set: { v in
                if let n = Double(v) { value = .number(n) }
                else if v.isEmpty { value = .empty }
            }))
                .keyboardType(.decimalPad)
                .textFieldStyle(.plain)
        case .checkbox:
            Toggle("", isOn: Binding(
                get: { if case .checkbox(let b) = value { return b }; return false },
                set: { value = .checkbox($0) }
            ))
            .labelsHidden()
        case .url:
            TextField("https://", text: textBinding(get: {
                if case .url(let s) = value { return s }; return ""
            }, set: { value = $0.isEmpty ? .empty : .url($0) }))
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .textFieldStyle(.plain)
        case .date:
            DatePicker("", selection: Binding(
                get: { dateFromValue() ?? .now },
                set: { value = .date(isoDay($0)) }
            ), displayedComponents: .date)
                .labelsHidden()
        case .selection(let options):
            Picker("", selection: Binding(
                get: { if case .selection(let s) = value, let s { return s }; return "" },
                set: { value = $0.isEmpty ? .empty : .selection($0) }
            )) {
                Text("None").tag("")
                ForEach(options, id: \.self) { opt in Text(opt).tag(opt) }
            }
            .labelsHidden()
        case .selectionMultiple(let options):
            MultiSelectInline(options: options, value: $value)
        default:
            Text(value.displayText.isEmpty ? "—" : value.displayText)
                .foregroundStyle(.secondary)
        }
    }

    /// Small wrapper that bridges the closure-based getter / setter
    /// to a Binding<String> usable by TextField.
    private func textBinding(get: @escaping () -> String,
                             set: @escaping (String) -> Void) -> Binding<String> {
        Binding(get: get, set: set)
    }

    private func dateFromValue() -> Date? {
        if case .date(let s) = value {
            var fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withFullDate]
            return fmt.date(from: s)
        }
        return nil
    }

    private func isoDay(_ d: Date) -> String {
        var fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withFullDate]
        return fmt.string(from: d)
    }
}

/// Pill-style multi-select inline. Tapping a chip toggles it. We
/// stay flat (no presentation sheet) so the user keeps context with
/// the title field above.
private struct MultiSelectInline: View {
    let options: [String]
    @Binding var value: PropertyValueFfi

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { opt in
                    let on = isSelected(opt)
                    Button {
                        Haptic.tap()
                        toggle(opt)
                    } label: {
                        Text(opt)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(on ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10),
                                        in: Capsule(style: .continuous))
                            .foregroundStyle(on ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func isSelected(_ opt: String) -> Bool {
        if case .selectionMultiple(let vs) = value { return vs.contains(opt) }
        return false
    }

    private func toggle(_ opt: String) {
        var set: [String]
        if case .selectionMultiple(let vs) = value { set = vs } else { set = [] }
        if let idx = set.firstIndex(of: opt) { set.remove(at: idx) } else { set.append(opt) }
        value = set.isEmpty ? .empty : .selectionMultiple(set)
    }
}
