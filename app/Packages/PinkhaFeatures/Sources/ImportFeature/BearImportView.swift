import SwiftUI
import UniformTypeIdentifiers
import PinkhaFFI
import PinkhaCore

// ── Import from Bear sheet ─────────────────────────────────────────────────────
//
// Bear stores notes in a SQLite book inside its app group container:
//   ~/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data/book.sqlite
//
// Flow:
//   1. User taps "Choose Bear book" → file picker opens
//   2. User selects Bear's book.sqlite
//   3. Tap "Import" → Rust extractor reads the SQLite and creates Pinkha leaves
//   4. Success screen shows leaf count; "Done" refreshes the list.

public struct BearImportView: View {
    public init(api: PinkhaApi?, onDone: @escaping () -> Void) {
        self.api = api
        self.onDone = onDone
    }
    public let api: PinkhaApi?
    public let onDone: () -> Void

    @State private var selectedPath: String?
    @State private var showingFilePicker = false
    @State private var importState: ImportState = .idle
    @Environment(\.dismiss) private var dismiss

    enum ImportState {
        case idle
        case running
        case done(ImportResultFfi)
        case failed(String)
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("Import from Bear")
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
                    allowedContentTypes: [UTType(filenameExtension: "sqlite") ?? .data],
                    allowsMultipleSelection: false
                ) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        // Start accessing the security-scoped resource so we can read the path.
                        if url.startAccessingSecurityScopedResource() {
                            selectedPath = url.path
                        } else {
                            selectedPath = url.path
                        }
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
                    showingFilePicker = true
                } label: {
                    HStack {
                        Image(systemName: "shelf")
                            .foregroundStyle(.tint)
                        if let path = selectedPath {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .foregroundStyle(.primary)
                        } else {
                            Text("Choose book.sqlite…")
                                .foregroundStyle(.secondary)
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
                Text("Bear Book")
            } footer: {
                Text("Bear's book is at:\n~/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data/book.sqlite")
                    .font(.caption2)
            }

            if case .running = importState {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Importing leaves…").foregroundStyle(.secondary)
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
                    let noun = result.leaves == 1 ? "leaf" : "leaves"
                    Text("\(result.leaves) \(noun) imported from Bear.")
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
                let result = try await api.importFromBear(dbPath: path)
                importState = .done(result)
            } catch let err as PinkhaError {
                importState = .failed(err.userMessage)
            } catch {
                importState = .failed(error.localizedDescription)
            }
        }
    }
}
