import SwiftUI
import PinkhaFFI

/// App-level preferences sheet. Reached from the Library home view's
/// 3-dot overflow menu. Sections grow as more settings get added — for
/// now: appearance (accent color) + reading aids (search spotlight).
public struct SettingsView: View {
    @Environment(AppSettings.self) var settings
    @Environment(\.dismiss) private var dismiss
    @State private var showingResetConfirm = false
    /// Le store n'est pas garanti présent : une feuille iOS 26 ne propage
    /// pas toujours l'environnement de la vue qui la présente. Optionnel
    /// plutôt que crash — la section d'export se tait alors.
    @Environment(PinkhaStore.self) private var store: PinkhaStore?
    @State private var exportEnCours = false
    @State private var archive: ArchivePrete?

    /// `URL` n'est pas `Identifiable`, et l'étendre depuis un paquet
    /// partagé imposerait ce choix à tout le projet. Une enveloppe locale
    /// coûte trois lignes et n'engage personne.
    private struct ArchivePrete: Identifiable {
        let id = UUID()
        let url: URL
    }
    @State private var erreurExport: String?

    public init() {}

    // ── Sauvegarde ────────────────────────────────────────────────────────

    /// Export manuel de toute la bibliothèque vers un fichier unique.
    ///
    /// Placé en tête des réglages, avant l'apparence : c'est le réglage dont
    /// la valeur ne se voit qu'un seul jour, celui où l'on en a besoin.
    @ViewBuilder
    private var sauvegardeSection: some View {
        Section {
            Button {
                exporter()
            } label: {
                HStack {
                    Label("Export library", systemImage: "arrow.down.document")
                    Spacer()
                    if exportEnCours { ProgressView() }
                }
            }
            .disabled(exportEnCours || store?.api == nil)

            // Une protection automatique dont l'utilisateur ne voit aucune
            // trace inquiète plus qu'elle ne rassure. Cette ligne est le
            // seul retour qu'il en aura — et le jour où elle affiche une
            // date ancienne, elle devient un avertissement.
            LabeledContent("Last automatic backup") {
                Text(derniereSauvegardeLisible)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("Writes your whole library — leaves, books, shelves and cover images — to a single file you can keep anywhere. The database inside is standard SQLite, readable without Pinkha.\n\nPinkha also keeps its own rolling snapshots on this device, taken automatically in the background.")
        }
        .sheet(item: $archive) { pret in
            ShareSheet(fichiers: [pret.url]) {
                // L'archive vit dans un dossier temporaire : une fois
                // partagée (ou annulée), on ne la laisse pas occuper le
                // disque de l'utilisateur.
                try? FileManager.default.removeItem(at: pret.url.deletingLastPathComponent())
                archive = nil
            }
        }
        .alert("Export failed", isPresented: Binding(
            get: { erreurExport != nil },
            set: { if !$0 { erreurExport = nil } }
        )) {
            Button("OK") { erreurExport = nil }
        } message: { Text(erreurExport ?? "") }
    }

    /// Date lisible du dernier instantané automatique, ou une mention
    /// explicite quand il n'y en a pas encore — « jamais » est une
    /// information, un tiret n'en est pas une.
    private var derniereSauvegardeLisible: String {
        guard let date = LibrarySnapshots.lastRun else { return "Never" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// Assemble l'archive hors du fil principal — un `VACUUM INTO` sur une
    /// grosse bibliothèque plus la copie des couvertures se comptent en
    /// secondes, et l'interface doit rester vivante pendant ce temps.
    private func exporter() {
        guard let api = store?.api, !exportEnCours else { return }
        exportEnCours = true
        Haptic.tap()
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try LibraryExport.makeArchive(api: api)
                }.value
                await MainActor.run {
                    exportEnCours = false
                    archive = ArchivePrete(url: url)
                    Haptic.success()
                }
            } catch {
                await MainActor.run {
                    exportEnCours = false
                    erreurExport = (error as? PinkhaError)?.userMessage ?? error.localizedDescription
                    Haptic.warning()
                }
            }
        }
    }

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                form
                resetFloatingButton
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
            }
        }
        // The sheet inherits its colorScheme from the *presenting*
        // view, which is below the app root's `.preferredColorScheme`.
        // Without this line, flipping the picker repaints the rest
        // of the app but leaves this sheet stuck on whatever scheme
        // was current when it appeared.
        .preferredColorScheme(settings.appearance.colorScheme)
        // `.preferredColorScheme(nil)` (for `.system`) doesn't release
        // a previously-forced scheme inside a sheet — SwiftUI caches
        // the scheme on the sheet's host. Forcing a fresh view
        // identity via `.id(...)` makes SwiftUI rebuild the sheet's
        // content tree, which re-evaluates the modifier from scratch
        // and finally lets `.system` follow the OS again. Cheap : the
        // sheet only re-instantiates when the user flips this picker.
        .id(settings.appearance)
    }

    private var form: some View {
        // Local `@Bindable` proxy onto the `@Environment` value — iOS 26
        // pattern when an Observable env value needs `$foo` bindings.
        @Bindable var settings = settings
        return Form {
                sauvegardeSection

                Section {
                    Picker(selection: $settings.appearance) {
                        ForEach(AppSettings.AppearanceMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.systemImage)
                                .tag(mode)
                        }
                    } label: { Text("Appearance") }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("System follows iOS. Light or Dark forces the theme app-wide, regardless of your device setting.")
                }

                Section {
                    accentColorPicker
                } header: {
                    Text("Accent color")
                } footer: {
                    Text("Applies to the tab bar, selected icons, cursor, and other system controls.")
                }

                Section {
                    Picker(selection: $settings.theme) {
                        ForEach(AppSettings.Theme.allCases) { theme in
                            Text(theme.label).tag(theme)
                        }
                    } label: { Text("Theme") }
                    // Right below the picker — sun ↔ moon toggle that
                    // flips every leaf to the theme's dark palette.
                    // Per-doc overrides from the reader sheet's
                    // sun/moon button always win.
                    Toggle(isOn: $settings.themeDarkVariant) {
                        HStack(spacing: 8) {
                            Image(systemName: settings.themeDarkVariant
                                  ? "moon.stars.fill"
                                  : "sun.horizon.fill")
                                .foregroundStyle(.secondary)
                            Text("Dark variant")
                        }
                    }
                    .tint(settings.accentColor)
                } header: {
                    Text("Theme")
                } footer: {
                    Text("Books-style reading theme applied to every doc. Each doc can override via its \"…\" overflow menu.")
                }

                Section {
                    Stepper(
                        value: $settings.recentCount,
                        in: 5...20,
                        step: 1
                    ) {
                        HStack {
                            Text("Recent strip count")
                            Spacer()
                            Text("\(settings.recentCount)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                } header: {
                    Text("Recents")
                } footer: {
                    Text("How many leaves appear in the horizontal strip at the top of the Library home. Bounded between 5 and 20.")
                }

                Section {
                    Toggle("Cursor follows accent", isOn: $settings.cursorFollowsAccent)
                        .tint(settings.accentColor)
                        .onChange(of: settings.cursorFollowsAccent) { _, _ in Haptic.toggle() }
                } header: {
                    Text("Text input")
                } footer: {
                    Text("On (default): the caret and selection use your accent color. Off: white, Notion-style.")
                }

                Section {
                    Toggle("Haptic feedback", isOn: $settings.hapticsEnabled)
                        .tint(settings.accentColor)
                        .onChange(of: settings.hapticsEnabled) { _, _ in Haptic.toggle() }
                } header: {
                    Text("Feedback")
                } footer: {
                    Text("On (default): every button tap, theme pick and toggle triggers a soft taptic click. Off: silent. Also respects the iOS system setting (Settings → Sounds & Haptics → System Haptics).")
                }

                Section {
                    Toggle("Link previews", isOn: $settings.linkPreviewsEnabled)
                        .tint(settings.accentColor)
                        .onChange(of: settings.linkPreviewsEnabled) { _, _ in Haptic.toggle() }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("On (default): embedded links load a title, image and icon from the site itself. Off: an embed shows only its address, and opening a leaf makes no network request.")
                }

                Section {
                    Toggle("Lock rotation", isOn: $settings.rotationLocked)
                        .tint(settings.accentColor)
                        .onChange(of: settings.rotationLocked) { _, _ in Haptic.toggle() }
                } header: {
                    Text("Rotation")
                } footer: {
                    Text("Off (default): the app rotates between portrait and landscape with the device. On: stays in portrait whatever the device does — handy on iPhone while reading in bed.")
                }

                Section {
                    Toggle("Tint focused block", isOn: $settings.spotlightTinted)
                        .tint(settings.accentColor)
                        .onChange(of: settings.spotlightTinted) { _, _ in Haptic.toggle() }
                } header: {
                    Text("Search spotlight")
                } footer: {
                    Text("When you open a leaf from search, the rest of the page is blurred. Turn this on to also paint a soft tint behind the matched block.")
                }

                Section {
                    Toggle("Hide bubble outside Library root", isOn: $settings.hidesAccessoryOutsideLibraryRoot)
                        .tint(settings.accentColor)
                        .onChange(of: settings.hidesAccessoryOutsideLibraryRoot) { _, _ in Haptic.toggle() }
                } header: {
                    Text("Create bubble")
                } footer: {
                    Text("Off (default): the create bubble stays visible everywhere. On: it only appears on the Library home view — quieter chrome inside shelves, leaves and books.")
                }

                Section {
                    Toggle("Long-press gesture", isOn: $settings.readerLongPressEnabled)
                        .tint(settings.accentColor)
                        .onChange(of: settings.readerLongPressEnabled) { _, _ in Haptic.toggle() }
                    Picker(selection: $settings.readerLongPressFingerCount) {
                        Text("2 fingers").tag(2)
                        Text("3 fingers").tag(3)
                    } label: {
                        Text("Fingers")
                    }
                    .pickerStyle(.segmented)
                    .disabled(!settings.readerLongPressEnabled)
                    .onChange(of: settings.readerLongPressFingerCount) { _, _ in Haptic.tap() }
                    Toggle("Hide status bar", isOn: $settings.readerHidesStatusBar)
                        .tint(settings.accentColor)
                        .onChange(of: settings.readerHidesStatusBar) { _, _ in Haptic.toggle() }
                } header: {
                    Text("Reader mode")
                } footer: {
                    Text("Hides every chrome element (tab bar, accessory bubble, toolbar) so you can just read. Trigger with a multi-finger long-press anywhere, or via the eyeglasses entry in the bubble's ⋯ menu. A floating ⊘ button always brings the chrome back.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .tint(.primary)
                }
            }
            .confirmationDialog(
                "Reset all settings to defaults?",
                isPresented: $showingResetConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    settings.resetToDefaults()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Appearance, accent color, recent strip count, spotlight tint, haptics and rotation lock will go back to their factory values.")
            }
    }

    /// Floating glass capsule pinned to the bottom-left of the
    /// settings sheet. Triggers a confirmation dialog before wiping
    /// the user's preferences back to their factory defaults.
    private var resetFloatingButton: some View {
        Button {
            showingResetConfirm = true
        } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
        .accessibilityLabel("Reset settings to defaults")
    }

    /// Compact swatch row — one tappable circle per accent option.
    /// The currently-selected swatch shows a checkmark, à la iOS
    /// Settings → Wallpaper.
    private var accentColorPicker: some View {
        HStack(spacing: 14) {
            ForEach(AppSettings.AccentChoice.allCases) { choice in
                Button {
                    settings.accentChoice = choice
                } label: {
                    ZStack {
                        Circle()
                            .fill(choice.color)
                            .frame(width: 32, height: 32)
                        if choice == settings.accentChoice {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .overlay(
                        Circle().stroke(.primary.opacity(0.15), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.label)
                .accessibilityAddTraits(choice == settings.accentChoice ? [.isSelected] : [])
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
