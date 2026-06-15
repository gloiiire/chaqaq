import Foundation
import PinkhaFFI
import PinkhaCore

// Context-aware creation overloads on `PinkhaStore`. Kept in the Notes
// layer because they reference `Composer.CreationContext` and
// `CreateDocumentSheet.StandaloneStyle` — feature-layer types that
// PinkhaStore (in PinkhaCore) must not depend on.

@MainActor
extension PinkhaStore {
    /// Context-aware note creation. Lands the new document in `context`
    /// after creation — moved into a folder, parented under another
    /// document, or left at the root. Returns the new document id so
    /// callers can chain follow-up work (e.g. signalling a Page block
    /// insertion to the active editor's view-model for `.document`
    /// context — done by the bubble's sheet handler, *not* here, to
    /// avoid racing with the editor's in-memory blocks array).
    @discardableResult
    func createNote(title: String, in context: Composer.CreationContext) -> String? {
        createNote(title: title, in: context, style: nil)
    }

    /// Same as [`createNote`] but applies the optional standalone
    /// `style` (cover / icon / theme) after the document lands.
    /// Best-effort : a failure on one style write is logged but
    /// doesn't roll the document back.
    @discardableResult
    func createNote(
        title: String,
        in context: Composer.CreationContext,
        style: CreateDocumentSheet.StandaloneStyle?
    ) -> String? {
        guard let api else { return nil }
        let docId = tryCatch(into: &errorMessage) {
            let docId = try api.createDocument(title: title)
            switch context {
            case .root:
                break
            case .folder(let folderId):
                try api.moveDocumentToFolder(docId: docId, folderId: folderId)
            case .document(let parentDocId):
                try api.updateDocumentParent(docId: docId, newParentDocId: parentDocId)
            }
            return docId
        }
        guard let docId else { return nil }
        if let style {
            applyStandaloneStyle(style, to: docId, api: api)
        }
        load()
        return docId
    }

    /// Creates a doc + files it as a new row of the given database.
    /// The orchestration (create document, fill the hidden page-link
    /// and Title columns, link the entry to the doc) lives in Rust —
    /// `create_document_in_database`. Returns the new document's id so
    /// the caller can navigate to it.
    @discardableResult
    func createNoteInDatabase(
        title: String,
        databaseId: String,
        propertyValues: [String: PropertyValueFfi],
        style: CreateDocumentSheet.StandaloneStyle? = nil
    ) -> String? {
        guard let api else { return nil }
        let docId = tryCatch(into: &errorMessage) {
            guard let json = try? JSONEncoder().encode(propertyValues),
                  let valuesJson = String(data: json, encoding: .utf8) else {
                throw PinkhaError.InvalidOperation(detail: "Failed to encode property values")
            }
            return try api.createDocumentInDatabase(
                dbId: databaseId, title: title, valuesJson: valuesJson)
        }
        guard let docId else { return nil }
        if let style {
            applyStandaloneStyle(style, to: docId, api: api)
        }
        load()
        return docId
    }

    /// Context-aware database creation. In `.document` context the new
    /// database is embedded in the parent doc via a `Database` block so
    /// it shows up inline. Folders aren't supported on databases yet —
    /// the database lands at the workspace root in that case.
    func createDatabase(title: String, in context: Composer.CreationContext) {
        guard let api else { return }
        tryCatch(into: &errorMessage) {
            let dbId = try api.createDatabase(title: title)
            if case .document(let parentDocId) = context {
                let dbBlock = BlockContentFfi.database(id: dbId)
                if let json = try? JSONEncoder().encode(dbBlock),
                   let payload = String(data: json, encoding: .utf8) {
                    _ = try? api.addBlock(docId: parentDocId, blockContentJson: payload)
                }
            }
        }
        load()
    }

    /// Context-aware folder creation. Honours folder nesting (parent
    /// folder = current folder); falls back to the root in `.document`
    /// context (folders can't live inside a document).
    func createFolder(name: String, in context: Composer.CreationContext) {
        let parentId: String?
        switch context {
        case .root, .document:    parentId = nil
        case .folder(let id):     parentId = id
        }
        _ = createFolder(name: name, parentId: parentId)
        load()
    }

    /// Writes the picked style overrides to the freshly-created
    /// doc. Custom cover bytes are persisted into the covers
    /// directory under the docId-derived filename ; the resulting
    /// short name lands in the meta row's `cover` column. Built-in
    /// gradient covers ship a direct identifier (e.g.
    /// `"cover.nebula"`) and skip the disk write.
    private func applyStandaloneStyle(
        _ style: CreateDocumentSheet.StandaloneStyle,
        to docId: String,
        api: PinkhaApi
    ) {
        if let data = style.customCoverData {
            if let name = try? DocumentViewModel.writeCoverImage(
                data: data, docId: docId, fileExtension: style.customCoverExt
            ) {
                try? api.updateDocumentCover(id: docId, cover: name)
            }
        } else if let cover = style.cover {
            try? api.updateDocumentCover(id: docId, cover: cover)
        }
        if let icon = style.icon {
            try? api.updateDocumentIcon(id: docId, icon: icon)
        }
        if let theme = style.theme {
            try? api.updateDocumentTheme(id: docId, theme: theme)
        }
        if let publishedAt = style.publishedAt {
            try? api.updateDocumentPublishedAt(
                id: docId, newPublishedAt: publishedAt)
        }
    }
}
