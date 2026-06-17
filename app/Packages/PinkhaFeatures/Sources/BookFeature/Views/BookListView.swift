import SwiftUI
import PinkhaFFI
import PinkhaCore
import LeafFeature

/// Mobile-first default — vertical column of cards, one per entry.
/// Each card shows :
/// * the linked doc's emoji icon (or a generic placeholder),
/// * the entry's title (Title property),
/// * the first multi-select chips inline below the title (truncated
///   if they overflow the row width),
/// * a relative date below the chips if no chips are present.
///
/// Tap the card to open the linked leaf. Long-press surfaces a
/// context menu with "Delete row". Grouping is delegated to the VM
/// via `groupedRows` ; this view just renders the result with
/// collapsible group headers.
public struct BookListView: View {
    @Bindable var vm: BookViewModel
    let api: PinkhaApi
    let onDisappear: () -> Void

    public var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(vm.groupedRows, id: \.title) { group in
                if vm.groupByPropertyId != nil {
                    BookGroupHeader(
                        title: group.title,
                        count: group.entries.count,
                        collapsed: vm.isGroupCollapsed(group.title),
                        onToggle: { vm.toggleGroup(group.title) },
                        onAdd: { vm.addEntry(forGroup: group.title) }
                    )
                }
                if !vm.isGroupCollapsed(group.title) {
                    ForEach(group.entries) { entry in
                        ListRow(
                            entry: entry,
                            properties: vm.properties,
                            leafId: vm.leafId(forEntryId: entry.id),
                            icon: vm.iconForEntry(entry),
                            api: api,
                            onDelete: { vm.deleteEntry(id: entry.id) },
                            onSetPublishDate: { iso in
                                vm.updateEntryPublishedAt(entryId: entry.id, isoDate: iso)
                            },
                            onDisappear: onDisappear
                        )
                        // Card-style background per row — same vocabulary
                        // as the LibraryView insetGrouped rows so the
                        // two list surfaces feel unified.
                        .background(
                            Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 80) // Breathing room for the floating add button.
    }
}

// ── Row ──────────────────────────────────────────────────────────────────────

/// Modal picker used to override an entry's `published_at`. Wraps a
/// `DatePicker` with a "Reset" option that clears the override so the
/// entry falls back to its `created_at`.
private struct PublishDatePickerSheet: View {
    let initial: Date
    let onDone: (Date?) -> Void

    @State private var selected: Date
    @Environment(\.dismiss) private var dismiss

    init(initial: Date, onDone: @escaping (Date?) -> Void) {
        self.initial = initial
        self.onDone = onDone
        self._selected = State(initialValue: initial)
    }

    public var body: some View {
        NavigationStack {
            Form {
                DatePicker("Publish date",
                           selection: $selected,
                           displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
                Section {
                    Button(role: .destructive) {
                        onDone(nil)
                    } label: {
                        Label("Reset to created date",
                              systemImage: "arrow.uturn.backward")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Publish date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onDone(selected) }
                }
            }
        }
    }
}

private struct ListRow: View {
    let entry: EntryFfi
    let properties: [PropertyFfi]
    let leafId: String?
    let icon: String?
    let api: PinkhaApi
    let onDelete: () -> Void
    let onSetPublishDate: (String) -> Void
    let onDisappear: () -> Void

    @Environment(TabManager.self) private var tabManager
    @Environment(PinkhaStore.self) private var store
    @State private var showingPublishDateSheet = false

    public var body: some View {
        Group {
            if let leafId {
                NavigationLink(destination: LeafView(
                    vm: tabManager.open(leafId: leafId, api: api),
                    onDisappear: onDisappear
                )) {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
        .contextMenu {
            // Pin / Unpin the underlying leaf when the row is backed
            // by one. The leaf still lives in the book ; pinning just
            // surfaces it in the home view's PINNED section, like any
            // other pinned leaf elsewhere in the library.
            if let leafId,
               let doc = store.allLeaves.first(where: { $0.id == leafId }) {
                Button {
                    withAnimation {
                        let isPinned = (doc.pinnedAt ?? "").isEmpty == false
                        store.setLeafPinned(leafId: leafId, pinned: !isPinned)
                    }
                } label: {
                    if (doc.pinnedAt ?? "").isEmpty {
                        Label("Pin", systemImage: "pin")
                    } else {
                        Label("Unpin", systemImage: "pin.slash")
                    }
                }
                .tint(.primary)
            }
            Button {
                showingPublishDateSheet = true
            } label: {
                Label(
                    entry.hasCustomPublishDate
                        ? "Change publish date"
                        : "Set publish date",
                    systemImage: "calendar")
            }
            .tint(.primary)
            if entry.hasCustomPublishDate {
                Button(role: .destructive) {
                    // Empty string on the FFI side resets the entry
                    // to the default "follow created_at" behaviour.
                    onSetPublishDate("")
                } label: {
                    Label("Reset publish date", systemImage: "arrow.uturn.backward")
                }
                .tint(.primary)
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Delete row", systemImage: "trash")
            }
            .tint(.red)
        }
        .sheet(isPresented: $showingPublishDateSheet) {
            PublishDatePickerSheet(
                initial: parseDate(entry.effectivePublishedAt) ?? Date()
            ) { picked in
                if let picked {
                    onSetPublishDate(ISO8601DateFormatter.fullRfc.string(from: picked))
                } else {
                    onSetPublishDate("")
                }
                showingPublishDateSheet = false
            }
            .presentationDetents([.medium])
        }
    }

    private func parseDate(_ iso: String) -> Date? {
        ISO8601DateFormatter.fullRfc.date(from: iso)
            ?? ISO8601DateFormatter().date(from: iso)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 14) {
            iconView
            VStack(alignment: .leading, spacing: 6) {
                Text(titleText.isEmpty ? "Untitled" : titleText)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                metadata
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var iconView: some View {
        Group {
            if let icon, !icon.isEmpty {
                Text(icon)
                    .font(.system(size: 32))
            } else {
                Image(systemName: "doc.text")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 34, height: 34, alignment: .center)
    }

    private var titleText: String {
        guard let titleProp = properties.first(where: {
            if case .title = $0.propertyType { return true }
            return false
        }) else { return "" }
        return entry.values[titleProp.id]?.displayText ?? ""
    }

    @ViewBuilder
    private var metadata: some View {
        let chips = inlineChips
        if chips.isEmpty {
            // No chips → show date / first text fallback if present.
            if let line = firstTextValue, !line.isEmpty {
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            HStack(spacing: 6) {
                ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                    Text(chip.label)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(chip.color.opacity(0.18),
                                    in: Capsule(style: .continuous))
                        .foregroundStyle(chip.color)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Chips harvested from the entry's multi-select properties — first
    /// 4 max so the row doesn't blow up. Color is derived from a stable
    /// hash of the chip label so the same tag always renders the same
    /// hue across sessions (Notion behaviour).
    private var inlineChips: [(label: String, color: Color)] {
        var out: [(String, Color)] = []
        for prop in properties {
            if case .selectionMultiple = prop.propertyType,
               case .selectionMultiple(let values) = entry.values[prop.id] ?? .empty {
                for v in values {
                    out.append((v, color(for: v)))
                    if out.count >= 4 { return out }
                }
            } else if case .selection = prop.propertyType,
                      case .selection(let v) = entry.values[prop.id] ?? .empty,
                      let v, !v.isEmpty {
                out.append((v, color(for: v)))
                if out.count >= 4 { return out }
            }
        }
        return out
    }

    private var firstTextValue: String? {
        for prop in properties {
            if case .title = prop.propertyType { continue }
            if case .text = prop.propertyType,
               case .text(let s) = entry.values[prop.id] ?? .empty,
               !s.isEmpty {
                return s
            }
            if case .date = prop.propertyType,
               case .date(let d) = entry.values[prop.id] ?? .empty,
               !d.isEmpty {
                return Self.friendlyDate(d)
            }
        }
        return nil
    }

    /// Turns a raw ISO 8601 timestamp into "Wed, Nov 29, 2024" — the
    /// 24-character `2024-11-29T17:37:00.000Z` string looks scary in
    /// a list row, even when it's correct. Falls back to the original
    /// string if parsing fails so we never lose information.
    static func friendlyDate(_ iso: String) -> String {
        guard let date = parseISO(iso) else { return iso }
        return date.formatted(
            .dateTime.weekday(.abbreviated).month(.abbreviated)
                .day().year()
        )
    }

    /// Tolerant ISO parser — Notion sends `…T17:37:00.000Z`,
    /// `…+02:00`, or bare `YYYY-MM-DD`. We try each in turn.
    static func parseISO(_ s: String) -> Date? {
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = full.date(from: s) { return d }
        let short = ISO8601DateFormatter()
        short.formatOptions = [.withInternetDateTime]
        if let d = short.date(from: s) { return d }
        let bare = DateFormatter()
        bare.dateFormat = "yyyy-MM-dd"
        return bare.date(from: s)
    }

    /// Stable label-→color hash. 8 hues = the same palette the block
    /// highlighter uses (kept in sync with `AppSettings.AccentChoice`)
    /// so chips feel native to the app rather than randomised.
    private func color(for label: String) -> Color {
        let palette: [Color] = [.pink, .purple, .blue, .teal, .green, .yellow, .orange, .red]
        var h: UInt32 = 5381
        for c in label.unicodeScalars { h = (h &* 33) &+ c.value }
        return palette[Int(h) % palette.count]
    }
}
