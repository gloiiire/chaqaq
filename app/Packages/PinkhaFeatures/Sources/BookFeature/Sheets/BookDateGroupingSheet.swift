import SwiftUI
import PinkhaFFI
import PinkhaCore

// ── Date-grouping config sheet ───────────────────────────────────────────────
//
// Lets the user partition the active view's entries into chronological
// buckets — Year, Month, Day, or Year > Month hierarchical. Distinct
// from the existing Select/Checkbox group-by surfaced as
// `groupByPropertyId` in the VM ; this sheet only touches `dateGrouping`.

public struct BookDateGroupingSheet: View {
    @Bindable var vm: BookViewModel
    @Environment(\.dismiss) private var dismiss

    /// Local draft of the config the user is editing. Committed to the
    /// VM (and through it, to Rust via the FFI) on every change so the
    /// list updates live as the user picks options. Initialised from
    /// the active view's persisted config.
    @State private var source: DateGroupingSourceFfi? = nil
    @State private var granularity: DateGranularityFfi = .yearMonth
    @State private var ascending: Bool = false

    public init(vm: BookViewModel) { self.vm = vm }

    public var body: some View {
        NavigationStack {
            Form {
                // ── Source ───────────────────────────────────────────────
                Section("Group by date column") {
                    sourceMenu
                }

                // ── Granularity ──────────────────────────────────────────
                if source != nil {
                    Section("Granularity") {
                        Picker("Granularity", selection: $granularity) {
                            Text("Year").tag(DateGranularityFfi.year)
                            Text("Month").tag(DateGranularityFfi.month)
                            Text("Year ▸ Month").tag(DateGranularityFfi.yearMonth)
                            Text("Day").tag(DateGranularityFfi.day)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()

                        Toggle("Newest first", isOn: Binding(
                            get: { !ascending },
                            set: { ascending = !$0 }
                        ))
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Group by date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.tint(.primary)
                }
                if source != nil {
                    ToolbarItem(placement: .destructiveAction) {
                        Button(role: .destructive) {
                            source = nil
                            vm.setDateGrouping(nil)
                            Haptic.tap()
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            .onAppear { hydrateFromActiveView() }
            .onChange(of: source) { _, _ in pushIfReady() }
            .onChange(of: granularity) { _, _ in pushIfReady() }
            .onChange(of: ascending) { _, _ in pushIfReady() }
        }
    }

    // ── Source picker ────────────────────────────────────────────────────

    /// Lists every viable source : the two built-ins (Created, Published)
    /// plus every Date property defined on the book. "None" clears the
    /// config and disables grouping.
    @ViewBuilder
    private var sourceMenu: some View {
        // "None" row — explicit so the picker semantics are obvious
        // (no group-by = flat list).
        Button {
            source = nil
            vm.setDateGrouping(nil)
            Haptic.tap()
        } label: {
            HStack {
                Label("None — show flat list", systemImage: "list.bullet")
                Spacer()
                if source == nil { Image(systemName: "checkmark") }
            }
        }
        .buttonStyle(.plain)

        sourceRow(label: "Created", systemImage: "calendar.badge.plus",
                  candidate: .created)
        sourceRow(label: "Published", systemImage: "calendar.badge.clock",
                  candidate: .published)

        ForEach(dateProperties) { prop in
            sourceRow(label: prop.name,
                      systemImage: "calendar",
                      candidate: .property(propertyId: prop.id))
        }
    }

    @ViewBuilder
    private func sourceRow(label: String,
                           systemImage: String,
                           candidate: DateGroupingSourceFfi) -> some View {
        Button {
            source = candidate
            Haptic.tap()
        } label: {
            HStack {
                Label(label, systemImage: systemImage)
                Spacer()
                if source == candidate { Image(systemName: "checkmark") }
            }
        }
        .buttonStyle(.plain)
    }

    // ── Derived ──────────────────────────────────────────────────────────

    private var dateProperties: [PropertyFfi] {
        vm.properties.filter {
            if case .date = $0.propertyType { return true }; return false
        }
    }

    // ── Sync helpers ─────────────────────────────────────────────────────

    private func hydrateFromActiveView() {
        if let g = vm.dateGrouping {
            source = g.source
            granularity = g.granularity
            ascending = g.ascending
        } else {
            source = nil
            granularity = .yearMonth
            ascending = false
        }
    }

    /// Pushes the current draft to the VM when a source is selected.
    /// "None" is handled inline by the source picker so we don't need
    /// to fire a redundant clear here.
    private func pushIfReady() {
        guard let source else { return }
        vm.setDateGrouping(DateGroupingFfi(
            source: source,
            granularity: granularity,
            ascending: ascending
        ))
    }
}
