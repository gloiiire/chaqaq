import SwiftUI
import PinkhaFFI
import PinkhaCore
import PinkhaDesignSystem

// ── Attach existing doc → book row ────────────────────────────────────────
//
// Files an existing leaf as a row of a chosen book. The doc's
// title is seeded into the Title column automatically so the row reads
// the same as the leaf ; every other property is editable inline before
// confirming. Same vocabulary as the "Add to a book" toggle of
// CreateLeafSheet, but works after the doc was created.

public struct BindLeafToBookSheet: View {
    /// UUID of the leaf to file as a row.
    public let leafId: String

    public init(leafId: String) {
        self.leafId = leafId
    }

    @Environment(PinkhaStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var pickedBookId: String? = nil
    @State private var pickedBook: BookFfi? = nil
    @State private var loadingSchema: Bool = false
    @State private var propertyValues: [String: PropertyValueFfi] = [:]
    @State private var saving: Bool = false
    @State private var errorMessage: String? = nil

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Book", selection: Binding(
                        get: { pickedBookId },
                        set: { newId in
                            pickedBookId = newId
                            Haptic.tap()
                            propertyValues = [:]
                            loadBookSchema()
                        }
                    )) {
                        Text("Choose…").tag(String?.none)
                        ForEach(store.books, id: \.id) { db in
                            Text(db.titlePlain.isEmpty ? "Untitled" : db.titlePlain)
                                .tag(Optional(db.id))
                        }
                    }
                } footer: {
                    Text("The leaf becomes a row of the picked book. Its title fills the Title column automatically.")
                }

                if loadingSchema {
                    Section {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                } else if let db = pickedBook {
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
            .navigationTitle("Add to book")
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
                    .disabled(pickedBookId == nil || saving)
                }
            }
            .alert("Couldn't add to the book",
                   isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    /// Properties of `db` we render in the inline editor — same logic
    /// as `CreateLeafSheet` : hide the system page-link column and
    /// the Title column (the doc's title fills it automatically).
    private func editableProperties(of db: BookFfi) -> [PropertyFfi] {
        db.properties.filter { prop in
            if prop.name == "__pinkha_page__" { return false }
            if case .title = prop.propertyType { return false }
            return true
        }
    }

    private func loadBookSchema() {
        guard let bookId = pickedBookId, let api = store.api else {
            pickedBook = nil
            return
        }
        loadingSchema = true
        Task.detached(priority: .userInitiated) {
            let decoded = try? api.getBook(id: bookId)
            await MainActor.run {
                pickedBook = decoded
                loadingSchema = false
            }
        }
    }

    private func commit() {
        guard let bookId = pickedBookId,
              let db = pickedBook,
              let api = store.api else { return }
        saving = true
        // Seed the Title property with the leaf's current plain
        // title so the row's Title column matches the leaf. We fetch
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
            _ = try api.attachLeafToBook(
                bookId: bookId,
                leafId: leafId,
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
        // The leaves / books list on the store is the cheapest
        // source of truth for a single doc's plain title here. Fall
        // back to listLeaves() for sub-pages which don't surface
        // in `store.leaves` (it's root-only).
        if let meta = store.leaves.first(where: { $0.id == leafId }) {
            return meta.titlePlain
        }
        if let api = store.api,
           let all = try? api.listLeaves(),
           let meta = all.first(where: { $0.id == leafId }) {
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
