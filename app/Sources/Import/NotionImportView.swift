import SwiftUI

// ── Import from Notion sheet ──────────────────────────────────────────────────
//
// Flow:
//   1. User taps "Connect with Notion" → OAuth (ASWebAuthenticationSession)
//      OR pastes a private integration token (`secret_xxx`) manually.
//   2. As soon as a token is in hand, we call `listNotionDatabases(token)`
//      which returns every DB the integration can see — no URL pasting needed.
//   3. User ticks one or more DBs. Optionally adds URLs manually for DBs not
//      yet shared with the integration via Notion's "Add connections" menu.
//   4. Tap Import → loop sequentially through the selection. Progress bar
//      shows current / total. The success screen aggregates the counts.
//   5. "Done" refreshes the home list.

struct NotionImportView: View {
    let api: PinkhaApi?
    let onDone: () -> Void

    @State private var token = ""
    @State private var availableDatabases: [NotionDatabaseSummaryFfi] = []
    @State private var selectedIds: Set<String> = []
    @State private var extraUrls: [String] = []
    @State private var databasesError: String? = nil
    @State private var isFetchingDatabases = false
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
        /// `current` = number of databases already done (0-indexed),
        /// `total` = total databases to import in this run.
        case running(current: Int, total: Int)
        case done(aggregated: ImportTotals)
        case failed(String)
    }

    /// Aggregated counts across every database imported in one Import button
    /// press — the success screen shows the sum, not per-DB breakdowns.
    struct ImportTotals {
        var databases: Int
        var documents: Int
        var entries: Int
        var blocks: Int
        var skipped: Int

        mutating func add(_ result: ImportResultFfi) {
            databases += 1
            documents += Int(result.documents)
            entries += Int(result.entries)
            blocks += Int(result.blocks)
            skipped += Int(result.skipped)
        }
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
                // persist immediately to the Keychain so a sheet dismiss/reopen
                // keeps the token. Also kicks off the auto-fetch via the token
                // onChange below.
                .onChange(of: oauth.token) { _, newToken in
                    if let newToken {
                        token = newToken
                        Keychain.save(newToken, for: KeychainKey.notionToken)
                    }
                }
                // Auto-fetch the database list whenever the token changes —
                // covers both manual paste (debounce-style: every keystroke
                // would be wasteful, but tokens are pasted at once in practice)
                // and OAuth completion. The fetch self-cancels if the token is
                // blank.
                .onChange(of: token) { _, newToken in
                    fetchDatabases(token: newToken)
                }
                .onAppear {
                    loadStoredToken()
                    if !token.isEmpty { fetchDatabases(token: token) }
                }
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
            connectSection
            tokenSection
            if !token.isEmpty {
                pickerSection
                manualUrlsSection
            }
            statusSection
        }
    }

    /// OAuth2 sign-in. Only shown when a public-integration client ID is
    /// configured at build time (otherwise OAuth isn't usable).
    @ViewBuilder
    private var connectSection: some View {
        if !NotionOAuth2.clientId.isEmpty {
            Section {
                Button {
                    // `Task { … }` inside a SwiftUI Button gets cancelled
                    // when the View re-renders (e.g. when oauth.isLoading
                    // flips). `Task.detached` runs free of any View lifecycle.
                    Task.detached { await oauth.authorize() }
                } label: {
                    HStack {
                        if oauth.isLoading {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text("Connect with Notion").fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(oauth.isLoading)
            } footer: {
                if let err = oauth.error {
                    Text(err).foregroundStyle(.red)
                } else {
                    Text("Sign in to import any database you've granted access to.")
                }
            }
        }
    }

    private var tokenSection: some View {
        Section {
            SecureField("secret_xxx…", text: $token)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        } header: {
            Text("API Token")
        } footer: {
            Text("Or paste a private integration token from notion.so/my-integrations.")
        }
    }

    /// Multi-select picker showing every DB the token can see. Auto-populated
    /// after a valid token, with a spinner while we're fetching and an inline
    /// error if Notion rejects the call.
    @ViewBuilder
    private var pickerSection: some View {
        Section {
            if isFetchingDatabases {
                HStack(spacing: 12) {
                    ProgressView().scaleEffect(0.8)
                    Text("Loading your databases…")
                        .foregroundStyle(.secondary)
                }
            } else if let err = databasesError {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if availableDatabases.isEmpty {
                Text("No database visible. In Notion, open a database → ⋯ → Connect to → \(integrationName).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(availableDatabases, id: \.id) { db in
                    DatabasePickerRow(
                        db: db,
                        isSelected: selectedIds.contains(db.id),
                        onTap: {
                            if selectedIds.contains(db.id) { selectedIds.remove(db.id) }
                            else { selectedIds.insert(db.id) }
                        }
                    )
                }
            }
        } header: {
            HStack {
                Text("Pick databases")
                Spacer()
                if !selectedIds.isEmpty {
                    Text("\(selectedIds.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
        }
    }

    /// Fallback for databases the integration hasn't been granted access to
    /// yet — the user can paste their URL and import them in the same run.
    @ViewBuilder
    private var manualUrlsSection: some View {
        Section {
            ForEach(Array(extraUrls.enumerated()), id: \.offset) { index, _ in
                HStack {
                    TextField("https://www.notion.so/…", text: $extraUrls[index])
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button {
                        extraUrls.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                extraUrls.append("")
            } label: {
                Label("Add database URL", systemImage: "plus")
            }
        } header: {
            Text("Or paste URLs manually")
        } footer: {
            Text("Useful for databases not yet shared with this integration.")
        }
    }

    /// Progress / error feedback while the actual import runs.
    @ViewBuilder
    private var statusSection: some View {
        if case .running(let current, let total) = state {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Importing \(current + 1) of \(total)…").foregroundStyle(.secondary)
                }
            }
        }
        if case .failed(let msg) = state {
            Section {
                Text(msg).foregroundStyle(.red).font(.footnote)
            }
        }
    }

    @ViewBuilder
    private var importButton: some View {
        if case .running = state {
            ProgressView().scaleEffect(0.8)
        } else {
            Button(importButtonLabel) { runImport() }
                .fontWeight(.semibold)
                .disabled(!canImport)
        }
    }

    /// Total = picked databases + non-empty extra URLs. Drives the button
    /// label so the user sees "Import 3 databases" instead of just "Import".
    private var totalToImport: Int {
        let urls = extraUrls.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return selectedIds.count + urls.count
    }

    private var importButtonLabel: String {
        switch totalToImport {
        case 0: return "Import"
        case 1: return "Import"
        case let n: return "Import \(n) databases"
        }
    }

    private var canImport: Bool {
        !token.trimmingCharacters(in: .whitespaces).isEmpty
            && totalToImport > 0
            && api != nil
    }

    /// Display name of the integration — used in the "share with X" hint.
    /// Falls back to "this integration" when we don't have a name to show.
    private var integrationName: String {
        let configured = Bundle.main.object(forInfoDictionaryKey: "NOTION_INTEGRATION_NAME") as? String
        if let name = configured, !name.isEmpty { return name }
        return "this integration"
    }

    // ── Success ───────────────────────────────────────────────────────────────

    @ViewBuilder
    private var successView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            if case .done(let totals) = state {
                VStack(spacing: 8) {
                    Text("Import complete!")
                        .font(.title3.weight(.semibold))
                    Text(successSummary(totals))
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

    private func successSummary(_ t: ImportTotals) -> String {
        let dbWord = t.databases == 1 ? "database" : "databases"
        let docWord = t.documents == 1 ? "note" : "notes"
        return "\(t.databases) \(dbWord), \(t.documents) \(docWord) imported."
    }

    // ── Fetch databases ───────────────────────────────────────────────────────

    private var isDone: Bool { if case .done = state { return true }; return false }

    private func fetchDatabases(token rawToken: String) {
        let cleaned = rawToken.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let api else {
            availableDatabases = []
            selectedIds = []
            databasesError = nil
            return
        }
        isFetchingDatabases = true
        databasesError = nil
        Task.detached(priority: .userInitiated) {
            do {
                let dbs = try api.listNotionDatabases(token: cleaned)
                await MainActor.run {
                    availableDatabases = dbs
                    isFetchingDatabases = false
                    // Drop selections that no longer exist (e.g. token
                    // changed to a different account).
                    let validIds = Set(dbs.map(\.id))
                    selectedIds = selectedIds.intersection(validIds)
                }
            } catch let err as PinkhaError {
                let message = err.userMessage
                await MainActor.run {
                    availableDatabases = []
                    databasesError = message
                    isFetchingDatabases = false
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    availableDatabases = []
                    databasesError = message
                    isFetchingDatabases = false
                }
            }
        }
    }

    // ── Import ────────────────────────────────────────────────────────────────

    private func runImport() {
        guard let api else { return }
        let t = token.trimmingCharacters(in: .whitespaces)
        let manualUrls = extraUrls
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Selection first (likely most-recent ordering from the picker), then
        // manual URLs in the order the user typed them. De-duplication is
        // best-effort — if the same DB is both picked and pasted, it imports
        // twice. Cheap to avoid: we'd need to normalise URLs to IDs, future
        // refinement if it matters in practice.
        let targets = Array(selectedIds) + manualUrls
        let total = targets.count
        guard total > 0 else { return }

        state = .running(current: 0, total: total)
        let coversDir = try? DocumentViewModel.coversDirectory().path

        Task.detached(priority: .userInitiated) {
            var totals = ImportTotals(databases: 0, documents: 0, entries: 0, blocks: 0, skipped: 0)
            for (index, target) in targets.enumerated() {
                await MainActor.run {
                    state = .running(current: index, total: total)
                }
                do {
                    let result = try api.importFromNotion(
                        token: t,
                        databaseId: target,
                        coversDir: coversDir
                    )
                    totals.add(result)
                } catch let err as PinkhaError {
                    let message = err.userMessage
                    await MainActor.run { state = .failed(message) }
                    return
                } catch {
                    let message = error.localizedDescription
                    await MainActor.run { state = .failed(message) }
                    return
                }
            }
            // All imports succeeded — persist the token for future runs.
            Keychain.save(t, for: KeychainKey.notionToken)
            // Copy the Rust-side debug log into Documents/ so it shows up
            // in Files.app for inspection. Best-effort — we silently swallow
            // file-system errors because the visible import shouldn't fail
            // for a missing log file.
            if let coversDir {
                let src = URL(fileURLWithPath: coversDir).appendingPathComponent("notion-debug.log")
                if let docs = try? FileManager.default.url(for: .documentDirectory,
                                                            in: .userDomainMask,
                                                            appropriateFor: nil,
                                                            create: true) {
                    let dst = docs.appendingPathComponent("notion-debug.log")
                    try? FileManager.default.removeItem(at: dst)
                    try? FileManager.default.copyItem(at: src, to: dst)
                }
            }
            await MainActor.run { state = .done(aggregated: totals) }
        }
    }
}

// ── Picker row ────────────────────────────────────────────────────────────────

/// Single row in the database picker. Shows emoji icon (or generic glyph),
/// title, and a checkmark when selected.
private struct DatabasePickerRow: View {
    @EnvironmentObject private var settings: AppSettings
    let db: NotionDatabaseSummaryFfi
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Icon: emoji if Notion gave one, generic database glyph
                // otherwise. Image icons aren't surfaced yet — the picker
                // never falls into them.
                if let emoji = db.iconEmoji, !emoji.isEmpty {
                    Text(emoji).font(.title3)
                } else {
                    Image(systemName: "tablecells")
                        .foregroundStyle(.secondary)
                }
                Text(displayTitle)
                    .lineLimit(1)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? settings.accentColor : Color.secondary)
                    .imageScale(.large)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var displayTitle: String {
        let trimmed = db.title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}
