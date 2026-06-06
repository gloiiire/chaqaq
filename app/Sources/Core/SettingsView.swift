import SwiftUI

/// App-level preferences sheet. Reached from the Notes home view's
/// 3-dot overflow menu. Sections grow as more settings get added — for
/// now: appearance (accent color) + reading aids (search spotlight).
struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
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
    }

    private var form: some View {
        Form {
                Section {
                    accentColorPicker
                } header: {
                    Text("Accent color")
                } footer: {
                    Text("Applies to the tab bar, selected icons, cursor, and other system controls.")
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
                } header: {
                    Text("Text input")
                } footer: {
                    Text("Off (default): the caret and selection are white, like Notion. On: they adopt your accent color.")
                }

                Section {
                    Toggle("Tint focused block", isOn: $settings.spotlightTinted)
                        .tint(settings.accentColor)
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
                Text("Accent color, recent strip count and the spotlight tint will go back to their factory values.")
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
