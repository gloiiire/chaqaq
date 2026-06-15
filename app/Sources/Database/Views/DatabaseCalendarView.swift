import SwiftUI

/// Month-grid calendar layout — each cell shows the date number and a
/// stack of the entries whose `propertyId` date falls on that day.
/// Tapping a day opens a sheet with the full entry list ; tapping an
/// entry inside opens the linked doc.
struct DatabaseCalendarView: View {
    @Bindable var vm: DatabaseViewModel
    let api: PinkhaApi
    let onDisappear: () -> Void

    @Environment(AppSettings.self) private var settings
    @State private var displayedMonth: Date = Date()
    @State private var selectedDay: Date?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            weekDayBar
            Divider()
            monthGrid
            Spacer(minLength: 0)
        }
        .sheet(item: dayBinding) { day in
            DayDetailSheet(
                day: day.date,
                entries: entriesByDay[day.dayKey] ?? [],
                vm: vm,
                api: api,
                onDisappear: onDisappear
            )
            .presentationDetents([.medium, .large])
        }
    }

    // ── Header (month label + prev/next) ─────────────────────────────────────

    private var header: some View {
        HStack {
            Button {
                Haptic.tap()
                displayedMonth = Calendar.current.date(
                    byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .padding(8)
            }
            .buttonStyle(.plain)

            Text(displayedMonth, format: .dateTime.month(.wide).year())
                .font(.headline)
                .frame(maxWidth: .infinity)

            Button {
                Haptic.tap()
                displayedMonth = Calendar.current.date(
                    byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .padding(8)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // ── Weekday names row ────────────────────────────────────────────────────

    private var weekDayBar: some View {
        HStack {
            ForEach(weekDaySymbols, id: \.self) { sym in
                Text(sym)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }

    private var weekDaySymbols: [String] {
        let cal = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = cal.locale
        var syms = formatter.shortStandaloneWeekdaySymbols ?? []
        // Rotate so the array starts on the user's first weekday.
        let first = cal.firstWeekday - 1
        if !syms.isEmpty {
            syms = Array(syms[first...]) + Array(syms[..<first])
        }
        return syms
    }

    // ── Month grid ───────────────────────────────────────────────────────────

    private var monthGrid: some View {
        let days = daysInDisplayedMonthGrid()
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7),
                          spacing: 0) {
            ForEach(days, id: \.self) { day in
                DayCell(
                    day: day,
                    inMonth: Calendar.current.isDate(
                        day, equalTo: displayedMonth, toGranularity: .month),
                    entries: entriesByDay[day.dayKey] ?? [],
                    onTap: { selectedDay = day }
                )
            }
        }
        .padding(.horizontal, 6)
    }

    /// Generates the 6×7 day grid that covers the displayed month and
    /// the trailing days of the previous / next month needed to fill
    /// the leading and trailing weeks.
    private func daysInDisplayedMonthGrid() -> [Date] {
        let cal = Calendar.current
        guard let monthRange = cal.range(of: .day, in: .month, for: displayedMonth),
              let firstOfMonth = cal.date(from:
                cal.dateComponents([.year, .month], from: displayedMonth)) else { return [] }
        let weekdayOfFirst = cal.component(.weekday, from: firstOfMonth)
        let leading = ((weekdayOfFirst - cal.firstWeekday) + 7) % 7
        let start = cal.date(byAdding: .day, value: -leading, to: firstOfMonth) ?? firstOfMonth
        let totalCells = ((leading + monthRange.count) + 6) / 7 * 7
        return (0..<totalCells).compactMap {
            cal.date(byAdding: .day, value: $0, to: start)
        }
    }

    // ── Entries indexed by yyyy-MM-dd key ────────────────────────────────────

    private var entriesByDay: [String: [EntryFfi]] {
        guard case .calendar(let propertyId) = vm.activeView?.type, !propertyId.isEmpty else {
            return [:]
        }
        var map: [String: [EntryFfi]] = [:]
        for e in vm.filteredEntries {
            if case .date(let iso) = e.values[propertyId] ?? .empty,
               let date = parseDate(iso) {
                map[Date.dayKey(date), default: []].append(e)
            }
        }
        return map
    }

    private func parseDate(_ iso: String) -> Date? {
        if let d = ISO8601DateFormatter().date(from: iso) { return d }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: iso)
    }

    // ── Day-selection sheet binding ─────────────────────────────────────────

    private var dayBinding: Binding<DaySheetItem?> {
        Binding(
            get: { selectedDay.map { DaySheetItem(date: $0) } },
            set: { selectedDay = $0?.date }
        )
    }

    private struct DaySheetItem: Identifiable {
        let date: Date
        var id: TimeInterval { date.timeIntervalSinceReferenceDate }
        var dayKey: String { Date.dayKey(date) }
    }
}

private extension Date {
    var dayKey: String { Date.dayKey(self) }
    static func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

private struct DayCell: View {
    let day: Date
    let inMonth: Bool
    let entries: [EntryFfi]
    let onTap: () -> Void

    @Environment(AppSettings.self) private var settings

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(day, format: .dateTime.day())
                    .font(.caption.weight(inMonth ? .semibold : .regular))
                    .foregroundStyle(inMonth ? .primary : .tertiary)
                    .padding(.top, 4)
                if !entries.isEmpty {
                    Text("\(entries.count)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(settings.accentColor,
                                    in: Capsule(style: .continuous))
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(Rectangle().stroke(Color.separator.opacity(0.6), lineWidth: 0.3))
    }
}

private extension Color {
    static var separator: Color { Color(uiColor: .separator) }
}

private struct DayDetailSheet: View {
    let day: Date
    let entries: [EntryFfi]
    let vm: DatabaseViewModel
    let api: PinkhaApi
    let onDisappear: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if entries.isEmpty {
                    Text("No entries for this day.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { entry in
                        EntryRow(
                            entry: entry,
                            properties: vm.properties,
                            icon: vm.iconForEntry(entry),
                            docId: vm.documentId(forEntryId: entry.id),
                            api: api,
                            onDisappear: onDisappear
                        )
                    }
                }
            }
            .navigationTitle(Text(day, format: .dateTime.weekday(.wide).month().day()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.tint(.primary)
                }
            }
        }
    }

    private struct EntryRow: View {
        let entry: EntryFfi
        let properties: [PropertyFfi]
        let icon: String?
        let docId: String?
        let api: PinkhaApi
        let onDisappear: () -> Void

        @Environment(TabManager.self) private var tabManager

        var body: some View {
            Group {
                if let docId {
                    NavigationLink(destination: DocumentView(
                        vm: tabManager.open(docId: docId, api: api),
                        onDisappear: onDisappear
                    )) { label }.buttonStyle(.plain)
                } else { label }
            }
        }

        private var label: some View {
            HStack(spacing: 12) {
                if let icon, !icon.isEmpty { Text(icon).font(.title3) }
                Text(title.isEmpty ? "Untitled" : title)
                    .font(.body.weight(.medium))
            }
        }

        private var title: String {
            guard let p = properties.first(where: {
                if case .title = $0.propertyType { return true }; return false
            }) else { return "" }
            return entry.values[p.id]?.displayText ?? ""
        }
    }
}
