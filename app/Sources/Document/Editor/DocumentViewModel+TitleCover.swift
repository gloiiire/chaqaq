import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// ── Title and cover ───────────────────────────────────────────────────────────

extension DocumentViewModel {

    func saveTitle() {
        let oldTitle = lastPersistedTitle
        let newTitle = title
        guard oldTitle != newTitle else { return }
        do {
            try api.updateDocumentTitle(id: docId, newTitle: newTitle)
            lastPersistedTitle = newTitle
            undoMgr.registerUndo(withTarget: self) { vm in
                vm.title = oldTitle
                vm.saveTitle()
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func saveCover(_ newCover: String?) {
        let oldCover = self.cover
        guard oldCover != newCover else {
            cover = newCover
            return
        }
        do {
            cover = newCover
            try api.updateDocumentCover(id: docId, cover: newCover)
            undoMgr.registerUndo(withTarget: self) { vm in vm.saveCover(oldCover) }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Sets the page icon and persists to SQLite via the FFI. Mirrors
    /// `saveCover` for the icon slot — emoji, filename, or remote URL.
    func saveIcon(_ newIcon: String?) {
        let oldIcon = self.icon
        guard oldIcon != newIcon else {
            icon = newIcon
            return
        }
        do {
            icon = newIcon
            try api.updateDocumentIcon(id: docId, icon: newIcon)
            undoMgr.registerUndo(withTarget: self) { vm in vm.saveIcon(oldIcon) }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Toggles the read-only lock and persists. Source of truth for the lock
    /// flag — replaces the legacy per-doc UserDefaults entry. The toolbar
    /// reads `vm.locked` for the icon and calls this on tap; imports default
    /// the flag to `true` on the Rust side, the lock UI inherits naturally.
    func saveLocked(_ newLocked: Bool) {
        guard locked != newLocked else { return }
        let oldLocked = locked
        do {
            locked = newLocked
            try api.updateDocumentLocked(id: docId, locked: newLocked)
            undoMgr.registerUndo(withTarget: self) { vm in vm.saveLocked(oldLocked) }
        } catch { errorMessage = error.localizedDescription }
    }

    func saveCoverImage(data: Data, fileExtension: String = "jpg") {
        do {
            let nom = try Self.writeCoverImage(data: data, docId: docId, fileExtension: fileExtension)
            saveCover(nom)
        } catch { errorMessage = error.localizedDescription }
    }

    func saveCoverImageFromFile(_ url: URL) {
        let acces = url.startAccessingSecurityScopedResource()
        defer {
            if acces { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url)
            let ext = Self.imageExtension(url.pathExtension)
            let nom = try Self.writeCoverImage(data: data, docId: docId, fileExtension: ext)
            saveCover(nom)
        } catch { errorMessage = error.localizedDescription }
    }

    static func writeCoverImage(data: Data, docId: String, fileExtension: String) throws -> String {
        let directory = try coversDirectory()
        let nom = docId.replacingOccurrences(of: "/", with: "-") + "." + fileExtension
        let url = directory.appendingPathComponent(nom)
        try data.write(to: url, options: .atomic)
        return nom
    }

    /// Storage directory for cover images. Accessible by `DocumentDecorView`.
    static func coversDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Pinkha/Covers", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func imageExtension(_ ext: String) -> String {
        let cleaned = ext.lowercased()
        return ["jpg", "jpeg", "png", "heic", "webp"].contains(cleaned) ? cleaned : "jpg"
    }
}
