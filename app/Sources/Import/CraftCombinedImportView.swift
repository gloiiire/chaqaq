import SwiftUI
import UniformTypeIdentifiers
import PinkhaFFI

// ── Import from Craft (Combined) sheet ────────────────────────────────────────
//
// The user selects both:
//   • Craft's .realm database (block structure)
//   • The folder exported via "Export All → TextBundle" (titles + markdown)
//
// Pages with a matching textbundle use its markdown content and filename title.
// Pages without a textbundle counterpart fall back to realm block content.

struct CraftCombinedImportView: View {
    let api: PinkhaApi?
    let onDone: () -> Void

    @State private var realmPath: String?
    @State private var realmAutoDetected = false
    @State private var tbPath: String?
    @State private var showingRealmPicker = false
    @State private var showingFolderPicker = false
    @State private var importState: ImportState = .idle
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    enum ImportState {
        case idle
        case running
        case done(ImportResultFfi)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Import from Craft")
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
                .fileImporter(
                    isPresented: $showingRealmPicker,
                    allowedContentTypes: [UTType(filenameExtension: "realm") ?? .data],
                    allowsMultipleSelection: false
                ) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        _ = url.startAccessingSecurityScopedResource()
                        realmPath = url.path
                        realmAutoDetected = false
                    }
                }
                .fileImporter(
                    isPresented: $showingFolderPicker,
                    allowedContentTypes: [.folder],
                    allowsMultipleSelection: false
                ) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        _ = url.startAccessingSecurityScopedResource()
                        tbPath = url.path
                    }
                }
                .task { detectCraftDatabase() }
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
            // Realm file picker
            Section {
                Button { showingRealmPicker = true } label: {
                    HStack {
                        Image(systemName: "cylinder")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            if let path = realmPath {
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                    .foregroundStyle(.primary)
                                if realmAutoDetected {
                                    Text("Auto-detected · tap to change")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text("Choose Craft database…")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if realmPath != nil {
                            Image(systemName: realmAutoDetected ? "sparkles" : "checkmark")
                                .foregroundStyle(realmAutoDetected ? settings.accentColor : Color.green)
                                .font(.footnote.weight(.semibold))
                        }
                    }
                }
                .buttonStyle(.plain)
            } header: {
                Text("Craft Database (.realm)")
            } footer: {
                Text("Craft's database is in ~/Library/Containers/com.lukilabs.lukiapp/…/LukiMain_*.realm")
                    .font(.caption2)
            }

            // TextBundle folder picker
            Section {
                Button { showingFolderPicker = true } label: {
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            if let path = tbPath {
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                    .foregroundStyle(.primary)
                            } else {
                                Text("Choose export folder…")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if tbPath != nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.green)
                                .font(.footnote.weight(.semibold))
                        }
                    }
                }
                .buttonStyle(.plain)
            } header: {
                Text("TextBundle Export Folder")
            } footer: {
                Text("In Craft: ··· → Export → Export All → TextBundle. Select the exported folder here.")
                    .font(.caption2)
            }

            if case .running = importState {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Importing notes…").foregroundStyle(.secondary)
                    }
                }
            }

            if case .failed(let msg) = importState {
                Section {
                    Text(msg).foregroundStyle(.red).font(.footnote)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var importButton: some View {
        if case .running = importState {
            ProgressView().scaleEffect(0.8)
        } else {
            Button("Import") { runImport() }
                .fontWeight(.semibold)
                .disabled(!canImport)
        }
    }

    private var canImport: Bool { realmPath != nil && tbPath != nil && api != nil }

    // ── Success ───────────────────────────────────────────────────────────────

    private var successView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            if case .done(let r) = importState {
                VStack(spacing: 12) {
                    let noun = r.documents == 1 ? "note" : "notes"
                    Text("\(r.documents) \(noun) imported")
                        .font(.title3.weight(.semibold))

                    VStack(spacing: 6) {
                        if r.matchedTextbundle > 0 {
                            BreakdownRow(
                                icon: "doc.text",
                                color: .green,
                                label: "TextBundle",
                                count: Int(r.matchedTextbundle)
                            )
                        }
                        if r.realmFallback > 0 {
                            BreakdownRow(
                                icon: "cylinder",
                                color: .orange,
                                label: "Realm uniquement",
                                count: Int(r.realmFallback)
                            )
                        }
                        if r.textbundleOnly > 0 {
                            BreakdownRow(
                                icon: "folder",
                                color: .blue,
                                label: "TextBundle uniquement",
                                count: Int(r.textbundleOnly)
                            )
                        }
                    }
                    .padding(.top, 4)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ── Auto-detect realm ─────────────────────────────────────────────────────

    private func detectCraftDatabase() {
        guard realmPath == nil else { return }
        #if targetEnvironment(macCatalyst)
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let container = home
            .appendingPathComponent("Library/Containers/com.lukilabs.lukiapp")
            .appendingPathComponent("Data/Library/Application Support/com.lukilabs.lukiapp")

        guard let entries = try? fm.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let latest = entries
            .filter { $0.pathExtension == "realm" }
            .max {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a < b
            }

        if let url = latest {
            realmPath = url.path
            realmAutoDetected = true
        }
        #endif
    }

    // ── Import ────────────────────────────────────────────────────────────────

    private var isDone: Bool { if case .done = importState { return true }; return false }

    private func runImport() {
        guard let api, let realm = realmPath, let tb = tbPath else { return }
        importState = .running
        Task {
            do {
                let result = try await api.importFromCraftCombined(realmPath: realm, textbundleRoot: tb)
                importState = .done(result)
            } catch let err as PinkhaError {
                importState = .failed(err.userMessage)
            } catch {
                importState = .failed(error.localizedDescription)
            }
        }
    }
}

// ── BreakdownRow ──────────────────────────────────────────────────────────────

private struct BreakdownRow: View {
    let icon: String
    let color: Color
    let label: String
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(count)")
                .monospacedDigit()
                .fontWeight(.medium)
        }
        .font(.subheadline)
        .padding(.horizontal, 32)
    }
}
