import SwiftUI

// ── Import from Notion sheet ───────────────────────────────────────────────────
//
// Flow:
//   1. User enters their Notion Internal Integration Token (secret_xxx)
//   2. User pastes the database URL or ID
//   3. Tap "Import" → NotionImporter fetches schema + pages, creates Pinkha DB
//   4. Success screen shows entry count; "Done" calls onDone() to refresh the list.
//
// Setup (one-time): notion.so/my-integrations → New integration → copy token,
// then open the Notion database → … → Connections → connect your integration.

struct NotionImportView: View {
    let api: PinkhaApi?
    let onDone: () -> Void

    @StateObject private var importer = NotionImporter()
    @State private var token = ""
    @State private var notionUrl = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Import from Notion")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if !importer.isDone {
                            Button("Cancel") { dismiss() }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if importer.isDone {
                            Button("Done") { onDone(); dismiss() }
                                .fontWeight(.semibold)
                        } else {
                            importAction
                        }
                    }
                }
        }
        .presentationDetents([.large])
    }

    // ── Content ───────────────────────────────────────────────────────────────

    @ViewBuilder
    private var content: some View {
        if importer.isDone {
            successView
        } else {
            formView
        }
    }

    // ── Form ──────────────────────────────────────────────────────────────────

    private var formView: some View {
        Form {
            Section {
                SecureField("secret_xxx…", text: $token)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("API Token")
            } footer: {
                Text("Create an integration at notion.so/my-integrations and share your database with it.")
            }

            Section {
                TextField("https://www.notion.so/…", text: $notionUrl)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Database URL or ID")
            }

            if case .running(let msg) = importer.progress {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(msg).foregroundStyle(.secondary)
                    }
                }
            }

            if case .failed(let msg) = importer.progress {
                Section {
                    Text(msg).foregroundStyle(.red).font(.footnote)
                }
            }
        }
    }

    @ViewBuilder
    private var importAction: some View {
        switch importer.progress {
        case .running:
            ProgressView().scaleEffect(0.8)
        default:
            Button("Import") {
                guard let api else { return }
                importer.start(
                    token: token.trimmingCharacters(in: .whitespaces),
                    notionUrl: notionUrl.trimmingCharacters(in: .whitespaces),
                    api: api
                )
            }
            .fontWeight(.semibold)
            .disabled(!canImport)
        }
    }

    private var canImport: Bool {
        !token.trimmingCharacters(in: .whitespaces).isEmpty &&
        !notionUrl.trimmingCharacters(in: .whitespaces).isEmpty &&
        api != nil
    }

    // ── Success ───────────────────────────────────────────────────────────────

    private var successView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            if case .done(let result) = importer.progress {
                VStack(spacing: 8) {
                    Text("Import complete!")
                        .font(.title3.weight(.semibold))
                    let noun = result.entryCount == 1 ? "entry" : "entries"
                    Text("\(result.entryCount) \(noun) imported from \"\(result.databaseTitle)\".")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
