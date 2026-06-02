import SwiftUI

// ── Import from Notion sheet ───────────────────────────────────────────────────
//
// Flow (OAuth2):
//   1. User taps "Connect with Notion" → ASWebAuthenticationSession → token pre-filled
// Flow (integration token, manual):
//   1. User enters their Notion integration token (secret_xxx)
//   2. User pastes the database URL or ID
//   3. Tap "Import" → Rust extractor fetches schema + pages + blocks
//   4. Success screen shows counts; "Done" refreshes the list.

struct NotionImportView: View {
    let api: PinkhaApi?
    let onDone: () -> Void

    @State private var token = ""
    @State private var notionUrl = ""
    @State private var state: ImportState = .idle
    @StateObject private var oauth = NotionOAuth2()
    @Environment(\.dismiss) private var dismiss

    private func loadStoredToken() {
        if let stored = Keychain.load(KeychainKey.notionToken), !stored.isEmpty {
            token = stored
        }
    }

    enum ImportState {
        case idle
        case running
        case done(ImportResultFfi)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Import from Notion")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if !isDone { Button("Cancel") { dismiss() } }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if isDone {
                            Button("Done") { onDone(); dismiss() }.fontWeight(.semibold)
                        } else {
                            importButton
                        }
                    }
                }
                // When OAuth2 delivers a token, pre-fill the manual field and
                // persist immediately to the Keychain. Without the persist step,
                // dismissing and re-opening the sheet recreates the `@StateObject`
                // `oauth`, wiping `oauth.token` back to nil, and the user sees an
                // empty token field after a successful OAuth flow.
                .onChange(of: oauth.token) { _, newToken in
                    if let newToken {
                        token = newToken
                        Keychain.save(newToken, for: KeychainKey.notionToken)
                    }
                }
                .onAppear { loadStoredToken() }
        }
        .presentationDetents([.large])
    }

    // ── Content ───────────────────────────────────────────────────────────────

    @ViewBuilder
    private var content: some View {
        if isDone { successView } else { formView }
    }

    // ── Form ──────────────────────────────────────────────────────────────────

    private var formView: some View {
        Form {
            // OAuth2 sign-in (only shown when a public integration client ID is configured).
            if !NotionOAuth2.clientId.isEmpty {
                Section {
                    Button {
                        // `Task { … }` inside a Button closure inherits the
                        // surrounding View's task scope and gets cancelled
                        // when the View re-renders (e.g. because `oauth.isLoading`
                        // flips and SwiftUI re-evaluates the body). The OAuth
                        // flow then hangs silently with no error, no log past
                        // the first `@Published` mutation. `Task.detached`
                        // runs free of any View lifecycle.
                        Task.detached { await oauth.authorize() }
                    } label: {
                        HStack {
                            if oauth.isLoading {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text("Connect with Notion")
                                .fontWeight(.medium)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(oauth.isLoading)
                } footer: {
                    if let err = oauth.error {
                        Text(err).foregroundStyle(.red)
                    } else {
                        Text("Sign in with your Notion account to import a database you have access to.")
                    }
                }
            }

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

            if case .running = state {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Importing…").foregroundStyle(.secondary)
                    }
                }
            }

            if case .failed(let msg) = state {
                Section {
                    Text(msg).foregroundStyle(.red).font(.footnote)
                }
            }
        }
    }

    @ViewBuilder
    private var importButton: some View {
        if case .running = state {
            ProgressView().scaleEffect(0.8)
        } else {
            Button("Import") { runImport() }
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
            if case .done(let result) = state {
                VStack(spacing: 8) {
                    Text("Import complete!")
                        .font(.title3.weight(.semibold))
                    let noun = result.entries == 1 ? "entry" : "entries"
                    Text("\(result.entries) \(noun) and \(result.documents) \(result.documents == 1 ? "note" : "notes") imported.")
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

    // ── Import ────────────────────────────────────────────────────────────────

    private var isDone: Bool { if case .done = state { return true }; return false }

    private func runImport() {
        guard let api else { return }
        let t = token.trimmingCharacters(in: .whitespaces)
        let url = notionUrl.trimmingCharacters(in: .whitespaces)
        state = .running
        // `importFromNotion` is synchronous on the Rust side (it `block_on`s a
        // Tokio runtime internally because reqwest needs one and UniFFI's
        // executor isn't Tokio). Dispatch off the main thread via a detached
        // task so the call doesn't freeze the UI during the import.
        Task.detached(priority: .userInitiated) {
            do {
                let result = try api.importFromNotion(token: t, databaseId: url)
                // Re-confirm the token in the Keychain after a successful
                // import — the OAuth flow already persisted it on receipt,
                // but a manually-typed token also gets saved here.
                Keychain.save(t, for: KeychainKey.notionToken)
                await MainActor.run { state = .done(result) }
            } catch let err as PinkhaError {
                let message = err.userMessage
                await MainActor.run { state = .failed(message) }
            } catch {
                let message = error.localizedDescription
                await MainActor.run { state = .failed(message) }
            }
        }
    }
}
