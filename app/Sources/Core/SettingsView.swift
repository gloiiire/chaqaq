import SwiftUI

/// App-level preferences sheet. Reached from the Notes home view's
/// 3-dot overflow menu. Sections grow as more settings get added — for
/// now: appearance (accent color) + reading aids (search spotlight).
struct SettingsView: View {
    @Environment(AppSettings.self) var settings
    @Environment(\.dismiss) private var dismiss
    @State private var showingResetConfirm = false

    var body: some View {
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
                    Text("How many notes appear in the horizontal strip at the top of the Notes home. Bounded between 5 and 20.")
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
                    Text("When you open a note from search, the rest of the page is blurred. Turn this on to also paint a soft tint behind the matched block.")
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
