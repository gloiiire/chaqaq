import SwiftUI

// ── Store ─────────────────────────────────────────────────────────────────────

/// Observable store that owns the `PinkhaApi` connection and the document list.
@MainActor
final class PinkhaStore: ObservableObject {
    @Published var documents: [DocumentMetaFfi] = []
    @Published var errorMessage: String?

    private(set) var api: PinkhaApi?

    /// Opens the SQLite database and seeds it when running under UI-test launch arguments.
    func connect() {
        guard api == nil else { return }
        tryCatch(into: &errorMessage) {
            let dir  = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            // UI-test modes: use an ephemeral DB for reproducibility.
            let args = ProcessInfo.processInfo.arguments
            let isUITest = args.contains("--ui-test-data") || args.contains("--ui-test-clean")
            let dbName = isUITest ? "pinkha_uitest_\(UUID().uuidString).db" : "pinkha.db"
            let path = dir.appendingPathComponent(dbName).path
            api = try PinkhaApi(dbPath: path)
            if args.contains("--ui-test-data") {
                _ = try api?.createDocument(title: "Seeded Note 1")
                _ = try api?.createDocument(title: "Seeded Note 2")
            }
            // --ui-test-clean: empty DB, ideal for testing the empty state.
        }
        if api != nil { load() }
    }

    /// Refreshes the document list from the database.
    func load() {
        if let docs = tryCatch(into: &errorMessage, { try api?.listDocuments() ?? [] }) {
            documents = docs
        }
    }

    /// Creates a new document and reloads the list.
    func create(title: String) {
        if tryCatch(into: &errorMessage, { try api?.createDocument(title: title) }) != nil {
            load()
        }
    }

    /// Soft-deletes a document by id and reloads the list.
    func delete(id: String) {
        if tryCatch(into: &errorMessage, { try api?.deleteDocument(id: id) }) != nil {
            load()
        }
    }
}

// ── Main view ─────────────────────────────────────────────────────────────────

/// Root screen: document list with a greeting header, empty state, and FAB.
struct ContentView: View {
    @StateObject private var store = PinkhaStore()
    @State private var showingCreate = false
    @State private var newTitle = ""

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                List {
                    Section {
                        WelcomeHeader(greeting: greeting)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }

                    if store.documents.isEmpty {
                        Section {
                            EmptyState()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 48)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    } else {
                        Section("Documents") {
                            if let api = store.api {
                                ForEach(store.documents, id: \.id) { doc in
                                    NavigationLink(destination: DocumentView(docId: doc.id, api: api, onDisappear: store.load)) {
                                        DocumentRow(doc: doc)
                                    }
                                }
                                .onDelete { indexSet in
                                    for i in indexSet {
                                        store.delete(id: store.documents[i].id)
                                    }
                                }
                            } else {
                                ProgressView()
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .toolbar(.hidden, for: .navigationBar)

                FloatingButton(icon: "square.and.pencil") {
                    showingCreate = true
                }
                .accessibilityIdentifier("createDocumentFAB")
                .padding(.trailing, 24)
                .padding(.bottom, 32)
            }
            .sheet(isPresented: $showingCreate) {
                CreateDocumentSheet(title: $newTitle) {
                    store.create(title: newTitle)
                    newTitle = ""
                    showingCreate = false
                } onCancel: {
                    newTitle = ""
                    showingCreate = false
                }
            }
            .errorAlert(message: $store.errorMessage, onRetry: store.load)
        }
        .onAppear { store.connect() }
    }

    /// Returns a time-appropriate greeting string (morning / afternoon / evening).
    private var greeting: String {
        let h = Calendar.current.component(.hour, from: .now)
        switch h {
        case 5..<12: return "Bonjour."
        case 12..<18: return "Bon après-midi."
        default:      return "Bonsoir."
        }
    }
}

// ── Components ────────────────────────────────────────────────────────────────

/// Large-title greeting shown at the top of the document list.
private struct WelcomeHeader: View {
    let greeting: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greeting)
                .font(.largeTitle.bold())
            Text("Tes notes, à toi.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Placeholder shown when there are no documents yet.
private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("Aucun document")
                    .font(.headline)
                Text("Appuie sur le bouton en bas à droite\npour créer ta première note.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// Floating action button shared between the home screen (square.and.pencil) and
/// the document editor (pencil.and.outline). Glass style + pulse animation + haptic feedback.
struct FloatingButton: View {
    let icon: String
    let action: () -> Void
    @State private var pulse = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.58)) {
                pulse = true
            }
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                withAnimation(.easeOut(duration: 0.18)) {
                    pulse = false
                }
            }
        } label: {
            ZStack {
                if pulse {
                    Circle()
                        .fill(Color("SelectionTint").opacity(0.18))
                        .frame(width: 54, height: 54)
                        .transition(.scale.combined(with: .opacity))
                }

                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .symbolEffect(.bounce, value: pulse)
            }
            .frame(width: 54, height: 54)
            .contentShape(Circle())
        }
        .buttonStyle(FloatingButtonStyle())
        .sensoryFeedback(.impact(flexibility: .soft), trigger: pulse)
    }
}

/// Custom `ButtonStyle` for `FloatingButton`: glass effect, scale-down on press, colour shadow.
private struct FloatingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .glassEffect(.regular.interactive(), in: .circle)
            .scaleEffect(configuration.isPressed ? 0.84 : 1)
            .rotationEffect(.degrees(configuration.isPressed ? -6 : 0))
            .shadow(color: Color("SelectionTint").opacity(configuration.isPressed ? 0.34 : 0.18),
                    radius: configuration.isPressed ? 20 : 12,
                    y: configuration.isPressed ? 8 : 6)
            .animation(.spring(response: 0.22, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

/// A single row in the document list, showing icon, title, and relative date.
struct DocumentRow: View {
    let doc: DocumentMetaFfi

    var body: some View {
        HStack(spacing: 12) {
            documentIcon

            VStack(alignment: .leading, spacing: 4) {
                Text(doc.titlePlain.isEmpty ? "Sans titre" : doc.titlePlain)
                    .font(.body.weight(.medium))
                if let date = formattedDate(doc.updatedAt) {
                    Text(date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    /// Renders the document icon: a custom emoji from UserDefaults, or a generic system image.
    @ViewBuilder
    private var documentIcon: some View {
        if let icon = UserDefaults.standard.string(forKey: Self.iconKey(docId: doc.id)), !icon.isEmpty {
            Text(icon)
                .font(.title2)
                .frame(width: 34, height: 34)
        } else {
            Image(systemName: "doc.text")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    /// Returns the UserDefaults key used to persist the emoji icon for a given document id.
    private static func iconKey(docId: String) -> String {
        "document.icon.\(docId)"
    }

    /// Formats an ISO 8601 timestamp as a relative date string (e.g. "2 hours ago").
    private func formattedDate(_ iso: String) -> String? {
        guard !iso.isEmpty else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) else { return nil }
        return date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }
}

/// Sheet presented when creating a new document. Accepts a title and calls `onCreate` or `onCancel`.
struct CreateDocumentSheet: View {
    @Binding var title: String
    let onCreate: () -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Titre du document", text: $title)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit {
                            guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                            onCreate()
                        }
                }
            }
            .navigationTitle("Nouveau document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onCancel) { Image(systemName: "xmark") }
                        .accessibilityLabel("Annuler")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { onCreate() } label: { Image(systemName: "checkmark") }
                        .accessibilityLabel("Créer")
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { focused = true }
    }
}
