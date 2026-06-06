import SwiftUI

/// App-level preferences sheet. Reached from the Notes home view's
/// 3-dot overflow menu. Sections grow as more settings get added — for
/// now: appearance (accent color) + reading aids (search spotlight).
struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
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
                    Toggle("Tint focused block", isOn: $settings.spotlightTinted)
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
        }
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
