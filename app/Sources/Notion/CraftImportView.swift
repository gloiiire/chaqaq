import SwiftUI
import UniformTypeIdentifiers

// ── Import from Craft sheet ────────────────────────────────────────────────────
//
// On macOS (Catalyst) the sheet auto-detects Craft's .realm file at its known
// container path — the user just taps "Import".
// On iOS the user must select the file manually via the file picker.

struct CraftImportView: View {
    let api: PinkhaApi?
    let onDone: () -> Void

    @State private var selectedPath: String?
    @State private var autoDetected = false
    @State private var showingFilePicker = false
    @State private var importState: ImportState = .idle
    @Environment(\.dismiss) private var dismiss

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
                    isPresented: $showingFilePicker,
                    allowedContentTypes: [UTType(filenameExtension: "realm") ?? .data],
                    allowsMultipleSelection: false
                ) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        _ = url.startAccessingSecurityScopedResource()
                        selectedPath = url.path
                        autoDetected = false
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
            Section {
                Button {
                    showingFilePicker = true
                } label: {
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            if let path = selectedPath {
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                    .foregroundStyle(.primary)
                                if autoDetected {
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
                        if selectedPath != nil {
                            Image(systemName: autoDetected ? "sparkles" : "checkmark")
                                .foregroundStyle(autoDetected ? Color.accentColor : Color.green)
                                .font(.footnote.weight(.semibold))
                        }
                    }
                }
                .buttonStyle(.plain)
            } header: {
                Text("Craft Database")
            } footer: {
                if autoDetected {
                    Text("Craft database detected automatically.")
                        .font(.caption2)
                } else {
                    Text("Craft's database is at:\n~/Library/Containers/com.lukilabs.lukiapp/Data/Library/Application Support/com.lukilabs.lukiapp/LukiMain_*.realm")
                        .font(.caption2)
                }
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

    private var canImport: Bool { selectedPath != nil && api != nil }

    // ── Success ───────────────────────────────────────────────────────────────

    private var successView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            if case .done(let result) = importState {
                VStack(spacing: 8) {
                    Text("Import complete!")
                        .font(.title3.weight(.semibold))
                    let noun = result.documents == 1 ? "note" : "notes"
                    Text("\(result.documents) \(noun) imported from Craft.")
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

    // ── Auto-detect ───────────────────────────────────────────────────────────

    private func detectCraftDatabase() {
        guard selectedPath == nil else { return }
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
            selectedPath = url.path
            autoDetected = true
        }
        #endif
    }

    // ── Import ────────────────────────────────────────────────────────────────

    private var isDone: Bool { if case .done = importState { return true }; return false }

    private func runImport() {
        guard let api, let path = selectedPath else { return }
        importState = .running
        Task {
            do {
                let result = try await api.importFromCraft(dbPath: path)
                importState = .done(result)
            } catch {
                importState = .failed(error.localizedDescription)
            }
        }
    }
}
