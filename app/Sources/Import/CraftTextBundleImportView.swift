import SwiftUI
import UniformTypeIdentifiers

// ── Import from Craft (TextBundle) sheet ──────────────────────────────────────
//
// The user selects the root folder exported from Craft ("Export All as TextBundle").
// On macOS (Catalyst) the folder picker works natively.
// On iOS the folder must be accessible via the Files app.

struct CraftTextBundleImportView: View {
    let api: PinkhaApi?
    let onDone: () -> Void

    @State private var selectedPath: String?
    @State private var showingFolderPicker = false
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
                    isPresented: $showingFolderPicker,
                    allowedContentTypes: [.folder],
                    allowsMultipleSelection: false
                ) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        _ = url.startAccessingSecurityScopedResource()
                        selectedPath = url.path
                    }
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
            Section {
                Button {
                    showingFolderPicker = true
                } label: {
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            if let path = selectedPath {
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                    .foregroundStyle(.primary)
                            } else {
                                Text("Choose export folder…")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if selectedPath != nil {
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

    // ── Import ────────────────────────────────────────────────────────────────

    private var isDone: Bool { if case .done = importState { return true }; return false }

    private func runImport() {
        guard let api, let path = selectedPath else { return }
        importState = .running
        Task {
            do {
                let result = try await api.importFromCraftTextbundle(rootDir: path)
                importState = .done(result)
            } catch let err as PinkhaError {
                importState = .failed(err.userMessage)
            } catch {
                importState = .failed(error.localizedDescription)
            }
        }
    }
}
