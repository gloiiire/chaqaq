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
    /// Accent for the Toggle's "on" track — without an explicit tint
    /// the track renders white-on-grouped-background and disappears
    /// against the sheet's near-white card material.
    @Environment(AppSettings.self) private var settings

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
                // Inherited at the top of the form so every Button row
                // (source picker) keeps a primary-coloured icon when
                // tapped — without it, iOS 26 paints the Label's icon
                // with the system accent (blue) on every selection
                // change. Matches the project-wide rule : new UI is
                // neutral by default, accent opt-in.
                // ── Source ───────────────────────────────────────────────
                Section("Group by date column") {
                    sourceMenu
                }

                // ── Granularity ──────────────────────────────────────────
                if source != nil {
                    // Granularity is rendered as a hand-rolled Button
                    // list rather than a `Picker(.inline)` because the
                    // inline picker's selection checkmark is drawn by
                    // an underlying UITableViewCell accessory whose
                    // colour comes from `UITableView.tintColor` — not
                    // from SwiftUI's `.tint()`. The accessory therefore
                    // ignores every modifier we throw at it and stays
                    // system-blue once the user mutates the selection.
                    // Custom rows give us full control + match the
                    // visual vocabulary of the Source picker above.
                    Section("Granularity") {
                        granularityRow("Year", value: .year)
                        granularityRow("Month", value: .month)
                        granularityRow("Year ▸ Month", value: .yearMonth)
                        granularityRow("Day", value: .day)

                        Toggle("Newest first", isOn: Binding(
                            get: { !ascending },
                            set: { ascending = !$0 }
                        ))
                        // Toggle takes its `on`-state colour from the
                        // ambient tint. The sheet-wide .tint(.primary)
                        // would render the track white on a near-white
                        // grouped background — invisible. Override
                        // explicitly with the user's accent so the
                        // toggled state pops the same way it does in
                        // Settings.
                        .tint(settings.accentColor)
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
        .tint(.primary)
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
            sourceRowLabel(text: "None — show flat list",
                           systemImage: "list.bullet",
                           selected: source == nil)
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

    /// Granularity row — mirrors `sourceRow` shape (text + checkmark)
    /// but without an icon. Wired straight to the `granularity` state
    /// so `onChange(of: granularity)` pushes the new config. The
    /// `.contentShape(Rectangle())` makes the whole row tappable —
    /// without it `.buttonStyle(.plain)` only registers taps on the
    /// label's intrinsic content (the text + the checkmark), leaving
    /// the empty space pushed by the Spacer dead.
    @ViewBuilder
    private func granularityRow(_ label: String,
                                value: DateGranularityFfi) -> some View {
        Button {
            granularity = value
            Haptic.tap()
        } label: {
            HStack {
                Text(label).foregroundStyle(.primary)
                Spacer()
                if granularity == value {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.primary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sourceRow(label: String,
                           systemImage: String,
                           candidate: DateGroupingSourceFfi) -> some View {
        Button {
            source = candidate
            Haptic.tap()
        } label: {
            sourceRowLabel(text: label,
                           systemImage: systemImage,
                           selected: source == candidate)
        }
        .buttonStyle(.plain)
    }

    /// Forces monochrome rendering + primary foreground on the icon so
    /// SF Symbols with multi-tone payloads (`calendar.badge.plus`,
    /// `calendar.badge.clock`, plain `calendar`) don't fall back to
    /// their hierarchical / multicolor variants once a row has been
    /// tapped. Without this the bare `Label(_, systemImage:)` lets
    /// iOS 26 paint the icon in the system accent.
    @ViewBuilder
    private func sourceRowLabel(text: String,
                                systemImage: String,
                                selected: Bool) -> some View {
        HStack {
            Label {
                Text(text).foregroundStyle(.primary)
            } icon: {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.primary)
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.primary)
            }
        }
        // Hit zone covers the full row width — see granularityRow
        // for the rationale.
        .contentShape(Rectangle())
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
