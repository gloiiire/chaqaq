import SwiftUI

/// Notion-style toolbar pinned above the database body. Five action
/// surfaces, left-to-right :
/// 1. **View picker** — dropdown listing every named view (the active
///    one is shown ; tap = switch). Also lets the user create / rename
///    / delete views.
/// 2. **Search** — toggles an inline search field. Filters entries
///    case-insensitively as the user types.
/// 3. **Filter** — opens a sheet to add / remove per-property filters
///    on the active view.
/// 4. **Sliders** — opens a sheet to reorder / hide properties.
/// 5. **Add** — split button : tap the "+" creates a blank entry, tap
///    the chevron opens the quick-add menu (presets, future feature).
struct DatabaseToolbarView: View {
    @ObservedObject var vm: DatabaseViewModel
    @Binding var searchVisible: Bool
    /// Read from the environment so the toolbar always renders the
    /// chosen accent regardless of the `.tint(...)` inheritance up the
    /// navigation stack — opening the DB from the Notes tab (inside
    /// a doc's Page block) used to leave every accent slot white
    /// because that stack didn't propagate the env tint, while the
    /// Bases tab did. Reading it directly fixes both paths.
    @EnvironmentObject private var settings: AppSettings

    @State private var showFilterSheet = false
    @State private var showPropertiesSheet = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                viewPicker
                Spacer(minLength: 0)
                actionButtons
                if !vm.locked { addButton }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)

            if searchVisible {
                searchField
                    .padding(.horizontal, 18)
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .sheet(isPresented: $showFilterSheet) {
            DatabaseFilterSheet(vm: vm)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showPropertiesSheet) {
            DatabasePropertiesSheet(vm: vm)
                .presentationDetents([.medium, .large])
        }
    }

    // ── View picker ──────────────────────────────────────────────────────────

    private var viewPicker: some View {
        let accent = settings.accentColor
        return Menu {
            ForEach(vm.views) { view in
                Button {
                    Haptic.tap()
                    vm.activateView(id: view.id)
                } label: {
                    Label {
                        HStack {
                            Text(view.name)
                            if vm.activeViewId == view.id {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    } icon: {
                        Image(systemName: view.type.systemImage)
                    }
                }
            }
            Divider()
            Menu {
                Button {
                    Haptic.tap()
                    vm.addView(type: .list)
                } label: { Label("List", systemImage: "list.bullet") }
                Button {
                    Haptic.tap()
                    vm.addView(type: .table)
                } label: { Label("Table", systemImage: "tablecells") }
                Button {
                    Haptic.tap()
                    vm.addView(type: .gallery)
                } label: { Label("Gallery", systemImage: "square.grid.2x2") }
                Button {
                    Haptic.tap()
                    vm.addView(type: .kanban(groupBy: ""))
                } label: { Label("Board", systemImage: "rectangle.split.3x1") }
                Button {
                    Haptic.tap()
                    vm.addView(type: .calendar(propertyId: ""))
                } label: { Label("Calendar", systemImage: "calendar") }
            } label: {
                Label("Add view", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: vm.activeView?.type.systemImage ?? "list.bullet")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(accent)
                Text(vm.activeView?.name ?? "View")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
    }

    // ── Action cluster (search / filter / properties) ────────────────────────

    private var actionButtons: some View {
        HStack(spacing: 4) {
            iconButton(systemImage: "magnifyingglass",
                       active: searchVisible,
                       accessibility: "Search") {
                withAnimation(.easeOut(duration: 0.18)) {
                    searchVisible.toggle()
                    if !searchVisible { vm.searchQuery = "" }
                }
            }
            sortMenu
            iconButton(systemImage: "line.3.horizontal.decrease",
                       active: !vm.filters.isEmpty,
                       accessibility: "Filters") {
                showFilterSheet = true
            }
            iconButton(systemImage: "slider.horizontal.3",
                       active: false,
                       accessibility: "Properties") {
                showPropertiesSheet = true
            }
        }
    }

    /// Sort menu — exposes the two entry-level date sorts (Created
    /// and Published) plus a Clear option. Column-level sort still
    /// works via the column-header tap on the Table view ; this menu
    /// is the only path to a date sort on the List view.
    private var sortMenu: some View {
        Menu {
            Section("Sort by date") {
                Button {
                    Haptic.tap()
                    vm.setDateSort(.created, ascending: false)
                } label: {
                    Label("Created — newest first",
                          systemImage: vm.activeDateSort == .created ? "checkmark" : "calendar")
                }
                Button {
                    Haptic.tap()
                    vm.setDateSort(.created, ascending: true)
                } label: {
                    Label("Created — oldest first",
                          systemImage: vm.activeDateSort == .created ? "checkmark" : "calendar.badge.clock")
                }
                Button {
                    Haptic.tap()
                    vm.setDateSort(.published, ascending: false)
                } label: {
                    Label("Published — newest first",
                          systemImage: vm.activeDateSort == .published ? "checkmark" : "paperplane")
                }
                Button {
                    Haptic.tap()
                    vm.setDateSort(.published, ascending: true)
                } label: {
                    Label("Published — oldest first",
                          systemImage: vm.activeDateSort == .published ? "checkmark" : "paperplane.fill")
                }
            }
            if vm.activeSort != nil || vm.activeDateSort != nil {
                Section {
                    Button(role: .destructive) {
                        Haptic.tap()
                        vm.setDateSort(nil, ascending: true)
                    } label: {
                        Label("Clear sort", systemImage: "xmark.circle")
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(vm.activeDateSort != nil
                                 ? settings.accentColor : .secondary)
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Sort by date")
    }

    private func iconButton(
        systemImage: String,
        active: Bool,
        accessibility: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(active ? .primary : .secondary)
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
    }

    // ── Add button (split-button : "+" + chevron menu) ───────────────────────

    private var addButton: some View {
        HStack(spacing: 0) {
            Button {
                Haptic.tap()
                vm.addEntry()
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(.white.opacity(0.25))
                .frame(width: 1, height: 22)

            Menu {
                ForEach(quickAddPresets, id: \.label) { preset in
                    Button {
                        Haptic.tap()
                        vm.addEntry(preset: preset.label)
                    } label: {
                        Label(preset.label, systemImage: preset.systemImage)
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 36)
                    .contentShape(Rectangle())
            }
        }
        .background(settings.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // ── Search field (inline, shown when search is active) ───────────────────

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $vm.searchQuery)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !vm.searchQuery.isEmpty {
                Button {
                    vm.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var quickAddPresets: [(label: String, systemImage: String)] {
        // Static presets for now — future PR : per-DB user-defined
        // templates pulled from the VM. Keeping the list short so the
        // menu doesn't shadow the whole screen.
        [
            ("Quick note", "note.text"),
            ("Task", "checkmark.square"),
            ("Bookmark", "bookmark"),
        ]
    }
}
