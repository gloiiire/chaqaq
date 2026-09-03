import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import PinkhaComposer
import PinkhaFFI

// ── Title and cover ───────────────────────────────────────────────────────────

public extension LeafViewModel {

    func saveTitle() {
        let oldTitle = lastPersistedTitle
        let newTitle = title
        guard oldTitle != newTitle else { return }
        do {
            try api.updateLeafTitle(id: leafId, newTitle: newTitle)
            lastPersistedTitle = newTitle
            // Broadcast so every mounted LeafView refreshes the
            // copy of this doc it keeps in `docMetaById` for its
            // breadcrumb — otherwise a child still shows the stale
            // parent title until you pop back to root and re-enter.
            NotificationCenter.default.post(
                name: Composer.docTitleChangedNotification,
                object: nil,
                userInfo: ["leafId": leafId])
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
            try api.updateLeafCover(id: leafId, cover: newCover)
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
            try api.updateLeafIcon(id: leafId, icon: newIcon)
            undoMgr.registerUndo(withTarget: self) { vm in vm.saveIcon(oldIcon) }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Sets (or clears with `nil`) the per-leaf Books-style theme.
    /// Same optimistic-then-FFI pattern as `saveAccentColor`.
    func saveTheme(_ newTheme: String?) {
        guard theme != newTheme else { return }
        let previous = theme
        theme = newTheme
        do {
            try api.updateLeafTheme(id: leafId, theme: newTheme)
            undoMgr.registerUndo(withTarget: self) { vm in
                vm.saveTheme(previous)
            }
        } catch {
            errorMessage = error.localizedDescription
            theme = previous
        }
    }

    /// PRO-62 : persists the leaf's `ReaderSettings` bundle (font
    /// scale / family / bold / 4 spacings / justify / dark variant
    /// / custom-layout flag). Round-trips through JSON to mirror the
    /// Rust shape. Optimistic update, FFI persist, undo registration.
    func saveReaderSettings(_ newSettings: LeafReaderSettings) {
        guard readerSettings != newSettings else { return }
        let previous = readerSettings
        readerSettings = newSettings
        do {
            let json = String(
                data: try JSONEncoder().encode(newSettings),
                encoding: .utf8
            )
            try api.updateLeafReaderSettings(id: leafId, settingsJson: json)
            undoMgr.registerUndo(withTarget: self) { vm in
                vm.saveReaderSettings(previous)
            }
        } catch {
            errorMessage = error.localizedDescription
            readerSettings = previous
        }
    }

    /// Sets (or clears with `nil`) the per-leaf writing direction.
    /// Same pattern as `saveAccentColor` — optimistic UI update, then
    /// FFI persist, then undo registration.
    func saveTextDirection(_ newDirection: String?) {
        guard textDirection != newDirection else { return }
        let previous = textDirection
        textDirection = newDirection
        do {
            try api.updateLeafTextDirection(id: leafId, textDirection: newDirection)
            undoMgr.registerUndo(withTarget: self) { vm in
                vm.saveTextDirection(previous)
            }
        } catch {
            errorMessage = error.localizedDescription
            textDirection = previous
        }
    }

    /// Sets (or clears with `nil`) the per-leaf accent color and
    /// persists. Mutates the published value first so SwiftUI repaints
    /// the chrome immediately, then registers the inverse on the undo
    /// manager so cmd-Z restores the previous choice.
    func saveAccentColor(_ newColor: String?) {
        guard accentColor != newColor else { return }
        let previous = accentColor
        accentColor = newColor
        do {
            try api.updateLeafAccentColor(id: leafId, accentColor: newColor)
            undoMgr.registerUndo(withTarget: self) { vm in
                vm.saveAccentColor(previous)
            }
        } catch {
            errorMessage = error.localizedDescription
            accentColor = previous
        }
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
            try api.updateLeafLocked(id: leafId, locked: newLocked)
            undoMgr.registerUndo(withTarget: self) { vm in vm.saveLocked(oldLocked) }
        } catch { errorMessage = error.localizedDescription }
    }

    func saveCoverImage(data: Data, fileExtension: String = "jpg") {
        do {
            let nom = try Self.writeCoverImage(data: data, leafId: leafId, fileExtension: fileExtension)
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
            let nom = try Self.writeCoverImage(data: data, leafId: leafId, fileExtension: ext)
            saveCover(nom)
        } catch { errorMessage = error.localizedDescription }
    }

    static func writeCoverImage(data: Data, leafId: String, fileExtension: String) throws -> String {
        let directory = try coversDirectory()
        let nom = leafId.replacingOccurrences(of: "/", with: "-") + "." + fileExtension
        let url = directory.appendingPathComponent(nom)
        try data.write(to: url, options: .atomic)
        return nom
    }

    /// Storage directory for cover images. Accessible by `LeafDecorView`.
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

    static func imageExtension(_ ext: String) -> String {
        let cleaned = ext.lowercased()
        return ["jpg", "jpeg", "png", "heic", "webp"].contains(cleaned) ? cleaned : "jpg"
    }
}
