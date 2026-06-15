import SwiftUI
import PinkhaCore

// ── Leaf publish-date picker ──────────────────────────────────────────────
//
// Surfaced from the editor's overflow menu : lets the user override the
// leaf's effective publish date (independent of the immutable
// creation timestamp) and reset it back to the default at any time.
// Mirrors the per-row PublishDatePickerSheet on the book list view
// so the UX vocabulary stays consistent across notes and DB rows.

struct LeafPublishDateSheet: View {
    /// ISO-8601 string of the immutable creation timestamp. Used as
    /// the fallback when the user resets the override and as the
    /// implicit default when the override is empty.
    let createdAt: String
    /// Current override value. Empty string means "no override —
    /// fall back to `createdAt`".
    let publishedAt: String
    /// Called with an RFC 3339 timestamp on save, or with an empty
    /// string to reset back to the default behaviour.
    let onSave: (String) -> Void

    @State private var selected: Date = .now
    @Environment(\.dismiss) private var dismiss

    private var hasOverride: Bool {
        !publishedAt.isEmpty && publishedAt != createdAt
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Publish date",
                           selection: $selected,
                           displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)

                Section {
                    if let created = parseDate(createdAt) {
                        LabeledContent {
                            Text(created.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("Created", systemImage: "calendar.badge.plus")
                        }
                    }
                } footer: {
                    Text("The created date stays as a fingerprint of when the leaf came into being. The publish date is what controls how the doc surfaces in date-sorted views.")
                }

                if hasOverride {
                    Section {
                        Button(role: .destructive) {
                            Haptic.tap()
                            onSave("")
                            dismiss()
                        } label: {
                            Label("Reset to created date",
                                  systemImage: "arrow.uturn.backward")
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Publish date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Haptic.success()
                        onSave(ISO8601DateFormatter.fullRfc.string(from: selected))
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            // Initialise the picker with the effective publish date —
            // either the explicit override, or the creation
            // timestamp as the implicit default.
            let initial = publishedAt.isEmpty ? createdAt : publishedAt
            if let date = parseDate(initial) {
                selected = date
            }
        }
    }

    private func parseDate(_ iso: String) -> Date? {
        ISO8601DateFormatter.fullRfc.date(from: iso)
            ?? ISO8601DateFormatter().date(from: iso)
    }
}
