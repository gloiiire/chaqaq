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

    /// Returns documents whose title matches `query` (case-insensitive).
    func search(query: String) -> [DocumentMetaFfi] {
        guard !query.isEmpty, let api else { return [] }
        return (try? api.searchDocuments(query: query)) ?? []
    }
}

// ── Root: 3-tab layout ────────────────────────────────────────────────────────

/// Root view — three tabs: Notes, Databases, Search.
struct ContentView: View {
    @StateObject private var store = PinkhaStore()

    var body: some View {
        TabView {
            Tab("Notes", systemImage: "note.text") {
                NotesHomeView(store: store)
            }
            Tab("Bases", systemImage: "tablecells") {
                DatabasesHomeView()
            }
            Tab("Recherche", systemImage: "magnifyingglass") {
                SearchView(store: store)
            }
        }
        .onAppear { store.connect() }
        .errorAlert(message: $store.errorMessage, onRetry: store.load)
    }
}

// ── Tab 1 : Notes ─────────────────────────────────────────────────────────────

/// Home screen for the Notes tab: greeting, recent cards strip, full document list, FAB.
private struct NotesHomeView: View {
    @ObservedObject var store: PinkhaStore
    @State private var showingCreate = false
    @State private var newTitle = ""

    /// Up to 5 most recently modified documents for the "Récents" strip.
    private var recentDocs: [DocumentMetaFfi] {
        Array(store.documents.prefix(5))
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                List {
                    // ── Greeting ─────────────────────────────────────────
                    Section {
                        WelcomeHeader(greeting: greeting)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }

                    // ── Recent strip (only when documents exist) ──────────
                    if !store.documents.isEmpty {
                        Section {
                            RecentStrip(docs: recentDocs, api: store.api) {
                                store.load()
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
                        } header: {
                            SectionHeader(title: "Récents")
                        }
                    }

                    // ── All notes list ────────────────────────────────────
                    if store.documents.isEmpty {
                        Section {
                            EmptyState()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 48)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    } else {
                        Section {
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
                        } header: {
                            SectionHeader(title: "Toutes les notes")
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
        }
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

// ── Recent strip ──────────────────────────────────────────────────────────────

/// Horizontal scroll strip showing the most recently modified documents as cards.
private struct RecentStrip: View {
    let docs: [DocumentMetaFfi]
    let api: PinkhaApi?
    let onDisappear: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(docs, id: \.id) { doc in
                    if let api {
                        NavigationLink(destination: DocumentView(docId: doc.id, api: api, onDisappear: onDisappear)) {
                            RecentCard(doc: doc)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
        }
    }
}

/// A card in the recent strip — shows icon, title, and relative date.
private struct RecentCard: View {
    let doc: DocumentMetaFfi

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Icon
            Group {
                if let icon = storedIcon, !icon.isEmpty {
                    Text(icon)
                        .font(.title)
                } else {
                    Image(systemName: "doc.text")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, height: 36)

            Spacer()

            // Title + date
            VStack(alignment: .leading, spacing: 3) {
                Text(doc.titlePlain.isEmpty ? "Sans titre" : doc.titlePlain)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                if let date = formattedDate(doc.updatedAt) {
                    Text(date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .frame(width: 150, height: 140)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private var storedIcon: String? {
        UserDefaults.standard.string(forKey: "document.icon.\(doc.id)")
    }

    private func formattedDate(_ iso: String) -> String? {
        guard !iso.isEmpty else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) else { return nil }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

// ── Tab 2 : Databases ─────────────────────────────────────────────────────────

/// Placeholder for the Databases tab (backend complete, UI pending).
private struct DatabasesHomeView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "tablecells")
                    .font(.system(size: 52))
                    .foregroundStyle(.tertiary)
                VStack(spacing: 6) {
                    Text("Bases de données")
                        .font(.headline)
                    Text("Bientôt disponible.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Bases")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

// ── Tab 3 : Search ────────────────────────────────────────────────────────────

/// Search tab: real-time search across document titles.
private struct SearchView: View {
    @ObservedObject var store: PinkhaStore
    @State private var query = ""

    private var results: [DocumentMetaFfi] {
        query.isEmpty ? [] : store.search(query: query)
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    // Idle state — show a hint.
                    Label("Tape pour chercher", systemImage: "text.magnifyingglass")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .padding(.top, 32)
                } else if results.isEmpty {
                    Text("Aucun résultat pour « \(query) »")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .padding(.top, 32)
                } else {
                    if let api = store.api {
                        ForEach(results, id: \.id) { doc in
                            NavigationLink(destination: DocumentView(docId: doc.id, api: api, onDisappear: store.load)) {
                                DocumentRow(doc: doc)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Recherche")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Titres des notes…")
            .autocorrectionDisabled()
        }
    }
}

// ── Shared components ─────────────────────────────────────────────────────────

/// Bold section label with a subtle uppercase style.
private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .kerning(0.5)
    }
}

/// Large-title greeting shown at the top of the Notes tab.
private struct WelcomeHeader: View {
    let greeting: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting)
                .font(.largeTitle.bold())
            Text("Tes notes, à toi.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
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
