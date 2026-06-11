import SwiftUI

/// Mobile-first default — vertical column of cards, one per entry.
/// Each card shows :
/// * the linked doc's emoji icon (or a generic placeholder),
/// * the entry's title (Title property),
/// * the first multi-select chips inline below the title (truncated
///   if they overflow the row width),
/// * a relative date below the chips if no chips are present.
///
/// Tap the card to open the linked document. Long-press surfaces a
/// context menu with "Delete row". Grouping is delegated to the VM
/// via `groupedRows` ; this view just renders the result with
/// collapsible group headers.
struct DatabaseListView: View {
    @ObservedObject var vm: DatabaseViewModel
    let api: PinkhaApi
    let onDisappear: () -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(vm.groupedRows, id: \.title) { group in
                if vm.groupByPropertyId != nil {
                    DatabaseGroupHeader(
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
                            docId: vm.documentId(forEntryId: entry.id),
                            icon: vm.iconForEntry(entry),
                            api: api,
                            onDelete: { vm.deleteEntry(id: entry.id) },
                            onDisappear: onDisappear
                        )
                        Divider().padding(.leading, 60)
                    }
                }
            }
        }
        .padding(.bottom, 80) // Breathing room for the floating add button.
    }
}

// ── Row ──────────────────────────────────────────────────────────────────────

private struct ListRow: View {
    let entry: EntryFfi
    let properties: [PropertyFfi]
    let docId: String?
    let icon: String?
    let api: PinkhaApi
    let onDelete: () -> Void
    let onDisappear: () -> Void

    @EnvironmentObject private var tabManager: TabManager

    var body: some View {
        Group {
            if let docId {
                NavigationLink(destination: DocumentView(
                    vm: tabManager.open(docId: docId, api: api),
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
            Button(role: .destructive, action: onDelete) {
                Label("Delete row", systemImage: "trash")
            }
        }
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
                return d
            }
        }
        return nil
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
