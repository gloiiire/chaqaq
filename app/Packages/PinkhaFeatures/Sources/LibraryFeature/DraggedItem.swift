import Foundation
import CoreTransferable
import UniformTypeIdentifiers

// ── Drag & drop payload ───────────────────────────────────────────────────────
//
// Carries either a leaf id or a shelf id through SwiftUI's drag-and-drop
// machinery. Both shelves (nesting) and leaves (filing) can be dropped
// onto a ShelfRow ; this typed payload lets the drop destination tell
// them apart cleanly instead of fishing through `NSItemProvider` blobs.

/// What the user is currently dragging. Used by `ShelfRow.dropDestination`
/// to dispatch to the right `PinkhaStore` method.
public enum DraggedItem: Codable, Transferable {
    case leaf(String)
    case shelf(String)

    public static var transferRepresentation: some TransferRepresentation {
        // We define our own UTI so drops from outside the app (Files,
        // Drag from Photos, etc.) don't accidentally trigger a move.
        CodableRepresentation(contentType: .pinkhaItem)
    }

    /// Encodes the payload as an `NSItemProvider` for the legacy
    /// `.onDrag(_:)` / `.onDrop(of:isTargeted:perform:)` SwiftUI APIs.
    /// Required because the new Transferable-based `.dropDestination`
    /// does not fire when applied to a row inside a `List`
    /// (FB12980427 — confirmed by Apple DTS, still broken in iOS 26).
    /// The legacy NSItemProvider path is not affected by that bug.
    public var itemProvider: NSItemProvider {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.pinkhaItem.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    /// Decodes a single `NSItemProvider` carrying our pinkha UTI back to
    /// the typed payload. Hands the decoded item to `completion` on the
    /// main actor — call sites should mutate `PinkhaStore` from there.
    /// Skips providers that don't carry our UTI (cross-app drags from
    /// Files, Photos, etc.).
    public static func decode(_ providers: [NSItemProvider],
                              completion: @escaping @Sendable (DraggedItem) -> Void) {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.pinkhaItem.identifier)
        }) else { return }
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.pinkhaItem.identifier) { data, _ in
            guard let data,
                  let decoded = try? JSONDecoder().decode(DraggedItem.self, from: data)
            else { return }
            DispatchQueue.main.async { completion(decoded) }
        }
    }
}

public extension UTType {
    /// Custom drag UTI for in-app shelf / leaf moves. Exported in
    /// `Info.plist` would matter for cross-app drags ; here we just
    /// need a stable identifier the system can hash on.
    static let pinkhaItem = UTType(exportedAs: "com.gloiiire.pinkha.draggedItem")
}
