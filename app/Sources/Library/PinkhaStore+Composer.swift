import Foundation
import PinkhaFFI
import PinkhaCore

// Context-aware creation overloads on `PinkhaStore`. Kept in the Notes
// layer because they reference `Composer.CreationContext` and
// `CreateLeafSheet.StandaloneStyle` — feature-layer types that
// PinkhaStore (in PinkhaCore) must not depend on.

@MainActor
extension PinkhaStore {
    /// Context-aware note creation. Lands the new leaf in `context`
    /// after creation — moved into a shelf, parented under another
    /// leaf, or left at the root. Returns the new leaf id so
    /// callers can chain follow-up work (e.g. signalling a Page block
    /// insertion to the active editor's view-model for `.leaf`
    /// context — done by the bubble's sheet handler, *not* here, to
    /// avoid racing with the editor's in-memory blocks array).
    @discardableResult
    func createNote(title: String, in context: Composer.CreationContext) -> String? {
        createNote(title: title, in: context, style: nil)
    }

    /// Same as [`createNote`] but applies the optional standalone
    /// `style` (cover / icon / theme) after the leaf lands.
    /// Best-effort : a failure on one style write is logged but
    /// doesn't roll the leaf back.
    @discardableResult
    func createNote(
        title: String,
        in context: Composer.CreationContext,
        style: CreateLeafSheet.StandaloneStyle?
    ) -> String? {
        guard let api else { return nil }
        let leafId = tryCatch(into: &errorMessage) {
            let leafId = try api.createLeaf(title: title)
            switch context {
            case .root:
                break
            case .shelf(let shelfId):
                try api.moveLeafToShelf(leafId: leafId, shelfId: shelfId)
            case .leaf(let parentLeafId):
                try api.updateLeafParent(leafId: leafId, newParentLeafId: parentLeafId)
            }
            return leafId
        }
        guard let leafId else { return nil }
        if let style {
            applyStandaloneStyle(style, to: leafId, api: api)
        }
        load()
        return leafId
    }

    /// Creates a doc + files it as a new row of the given book.
    /// The orchestration (create leaf, fill the hidden page-link
    /// and Title columns, link the entry to the doc) lives in Rust —
    /// `create_leaf_in_book`. Returns the new leaf's id so
    /// the caller can navigate to it.
    @discardableResult
    func createNoteInBook(
        title: String,
        bookId: String,
        propertyValues: [String: PropertyValueFfi],
        style: CreateLeafSheet.StandaloneStyle? = nil
    ) -> String? {
        guard let api else { return nil }
        let leafId = tryCatch(into: &errorMessage) {
            guard let json = try? JSONEncoder().encode(propertyValues),
                  let valuesJson = String(data: json, encoding: .utf8) else {
                throw PinkhaError.InvalidOperation(detail: "Failed to encode property values")
            }
            return try api.createLeafInBook(
                bookId: bookId, title: title, valuesJson: valuesJson)
        }
        guard let leafId else { return nil }
        if let style {
            applyStandaloneStyle(style, to: leafId, api: api)
        }
        load()
        return leafId
    }

    /// Context-aware book creation. In `.leaf` context the new
    /// book is embedded in the parent doc via a `Book` block so
    /// it shows up inline. Shelves aren't supported on books yet —
    /// the book lands at the library root in that case.
    func createBook(title: String, in context: Composer.CreationContext) {
        guard let api else { return }
        tryCatch(into: &errorMessage) {
            let bookId = try api.createBook(title: title)
            if case .leaf(let parentLeafId) = context {
                let dbBlock = BlockContentFfi.book(id: bookId)
                if let json = try? JSONEncoder().encode(dbBlock),
                   let payload = String(data: json, encoding: .utf8) {
                    _ = try? api.addBlock(leafId: parentLeafId, blockContentJson: payload)
                }
            }
        }
        load()
    }

    /// Context-aware shelf creation. Honours shelf nesting (parent
    /// shelf = current shelf); falls back to the root in `.leaf`
    /// context (shelves can't live inside a leaf).
    func createShelf(name: String, in context: Composer.CreationContext) {
        let parentId: String?
        switch context {
        case .root, .leaf:    parentId = nil
        case .shelf(let id):     parentId = id
        }
        _ = createShelf(name: name, parentId: parentId)
        load()
    }

    /// Writes the picked style overrides to the freshly-created
    /// doc. Custom cover bytes are persisted into the covers
    /// directory under the leafId-derived filename ; the resulting
    /// short name lands in the meta row's `cover` column. Built-in
    /// gradient covers ship a direct identifier (e.g.
    /// `"cover.nebula"`) and skip the disk write.
    private func applyStandaloneStyle(
        _ style: CreateLeafSheet.StandaloneStyle,
        to leafId: String,
        api: PinkhaApi
    ) {
        if let data = style.customCoverData {
            if let name = try? LeafViewModel.writeCoverImage(
                data: data, leafId: leafId, fileExtension: style.customCoverExt
            ) {
                try? api.updateLeafCover(id: leafId, cover: name)
            }
        } else if let cover = style.cover {
            try? api.updateLeafCover(id: leafId, cover: cover)
        }
        if let icon = style.icon {
            try? api.updateLeafIcon(id: leafId, icon: icon)
        }
        if let theme = style.theme {
            try? api.updateLeafTheme(id: leafId, theme: theme)
        }
        if let publishedAt = style.publishedAt {
            try? api.updateLeafPublishedAt(
                id: leafId, newPublishedAt: publishedAt)
        }
    }
}
