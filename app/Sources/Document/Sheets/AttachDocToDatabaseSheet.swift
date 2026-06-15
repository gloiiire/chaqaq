import SwiftUI
import PinkhaFFI

// ── Attach existing doc → database row ────────────────────────────────────────
//
// Files an existing document as a row of a chosen database. The doc's
// title is seeded into the Title column automatically so the row reads
// the same as the note ; every other property is editable inline before
// confirming. Same vocabulary as the "Add to a database" toggle of
// CreateDocumentSheet, but works after the doc was created.

struct AttachDocToDatabaseSheet: View {
    /// UUID of the document to file as a row.
    let docId: String

    @Environment(PinkhaStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var pickedDatabaseId: String? = nil
    @State private var pickedDatabase: DatabaseFfi? = nil
    @State private var loadingSchema: Bool = false
    @State private var propertyValues: [String: PropertyValueFfi] = [:]
    @State private var saving: Bool = false
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Database", selection: Binding(
                        get: { pickedDatabaseId },
                        set: { newId in
                            pickedDatabaseId = newId
                            Haptic.tap()
                            propertyValues = [:]
                            loadDatabaseSchema()
                        }
                    )) {
                        Text("Choose…").tag(String?.none)
                        ForEach(store.databases, id: \.id) { db in
                            Text(db.titlePlain.isEmpty ? "Untitled" : db.titlePlain)
                                .tag(Optional(db.id))
                        }
                    }
                } footer: {
                    Text("The document becomes a row of the picked database. Its title fills the Title column automatically.")
                }

                if loadingSchema {
                    Section {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                } else if let db = pickedDatabase {
                    Section("Properties") {
                        ForEach(editableProperties(of: db)) { prop in
                            PropertyInputRow(
                                property: prop,
                                value: Binding(
                                    get: { propertyValues[prop.id] ?? .empty },
                                    set: { propertyValues[prop.id] = $0 }
                                )
                            )
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Add to database")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                    }
                    .tint(.primary)
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: commit) {
                        if saving {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "checkmark")
                        }
                    }
                    .accessibilityLabel("Save")
                    .disabled(pickedDatabaseId == nil || saving)
                }
            }
            .alert("Couldn't add to the database",
                   isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    /// Properties of `db` we render in the inline editor — same logic
    /// as `CreateDocumentSheet` : hide the system page-link column and
    /// the Title column (the doc's title fills it automatically).
    private func editableProperties(of db: DatabaseFfi) -> [PropertyFfi] {
        db.properties.filter { prop in
            if prop.name == "__pinkha_page__" { return false }
            if case .title = prop.propertyType { return false }
            return true
        }
    }

    private func loadDatabaseSchema() {
        guard let dbId = pickedDatabaseId, let api = store.api else {
            pickedDatabase = nil
            return
        }
        loadingSchema = true
        Task.detached(priority: .userInitiated) {
            let decoded = try? api.getDatabase(id: dbId)
            await MainActor.run {
                pickedDatabase = decoded
                loadingSchema = false
            }
        }
    }

    private func commit() {
        guard let dbId = pickedDatabaseId,
              let db = pickedDatabase,
              let api = store.api else { return }
        saving = true
        // Seed the Title property with the document's current plain
        // title so the row's Title column matches the note. We fetch
        // it here rather than caching on the store so a stale meta
        // can't desync the seeded value.
        var values = propertyValues
        if let titleProp = db.properties.first(where: {
            if case .title = $0.propertyType { return true }
            return false
        }) {
            let docTitle = currentDocTitle()
            if !docTitle.isEmpty {
                values[titleProp.id] = .title(plainTitleSpans(docTitle))
            }
        }
        do {
            let data = try JSONEncoder().encode(values)
            let valuesJson = String(decoding: data, as: UTF8.self)
            _ = try api.attachDocumentToDatabase(
                dbId: dbId,
                docId: docId,
                valuesJson: valuesJson)
            // Refresh the store so the row count + meta surfaces
            // pick up the new entry without waiting for an app
            // restart.
            store.load()
            Haptic.success()
            saving = false
            dismiss()
        } catch {
            saving = false
            errorMessage = error.localizedDescription
        }
    }

    private func currentDocTitle() -> String {
        // The notes / databases list on the store is the cheapest
        // source of truth for a single doc's plain title here. Fall
        // back to listDocuments() for sub-pages which don't surface
        // in `store.documents` (it's root-only).
        if let meta = store.documents.first(where: { $0.id == docId }) {
            return meta.titlePlain
        }
        if let api = store.api,
           let all = try? api.listDocuments(),
           let meta = all.first(where: { $0.id == docId }) {
            return meta.titlePlain
        }
        return ""
    }

    /// Single inline span carrying the doc title, no styles. The Rust
    /// PropertyValue::Title expects a Vec<InlineText> — keep parity
    /// with the import path (one styles-free span).
    private func plainTitleSpans(_ title: String) -> [InlineTextFfi] {
        [InlineTextFfi(content: title, styles: [])]
    }
}
