import Testing
import Foundation
import PinkhaFFI
@testable import PinkhaCore

// Une rotation qui garde les mauvais fichiers, ou qui efface ce qui ne lui
// appartient pas, serait pire que pas de sauvegarde du tout : elle donnerait
// une fausse tranquillité.
@Suite("Sauvegarde automatique — rotation réelle")
struct LibrarySnapshotsPersistenceTests {

    private func makeApi() throws -> (PinkhaApi, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_snap_\(UUID().uuidString).db")
        return (try PinkhaApi(dbPath: url.path), url)
    }

    @Test func snapshotReopensWithTheSameContent() throws {
        let (api, db) = try makeApi()
        defer { try? FileManager.default.removeItem(at: db) }
        _ = try api.createLeaf(title: "Sauvegardée")

        let dossier = FileManager.default.temporaryDirectory
            .appendingPathComponent("snaps_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dossier) }

        let chemin = try api.snapshotLibrary(dir: dossier.path, keep: 7)
        #expect(FileManager.default.fileExists(atPath: chemin))

        let restaure = try PinkhaApi(dbPath: chemin)
        #expect(try restaure.listLeaves().map(\.titlePlain) == ["Sauvegardée"])
    }

    @Test func listingReturnsNewestFirst() throws {
        let (api, db) = try makeApi()
        defer { try? FileManager.default.removeItem(at: db) }
        _ = try api.createLeaf(title: "Contenu")

        let dossier = FileManager.default.temporaryDirectory
            .appendingPathComponent("snaps_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dossier) }

        _ = try api.snapshotLibrary(dir: dossier.path, keep: 7)
        // L'horodatage a la seconde pour résolution : sans pause les deux
        // instantanés porteraient le même nom.
        Thread.sleep(forTimeInterval: 1.1)
        let dernier = try api.snapshotLibrary(dir: dossier.path, keep: 7)

        let liste = try api.listSnapshots(dir: dossier.path)
        #expect(liste.count == 2)
        #expect(liste.first == URL(fileURLWithPath: dernier).lastPathComponent)
    }

    /// Le dossier n'existe pas encore au tout premier lancement.
    @Test func listingAnAbsentDirectoryIsEmptyNotAnError() throws {
        let (api, db) = try makeApi()
        defer { try? FileManager.default.removeItem(at: db) }
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("jamais_\(UUID().uuidString)", isDirectory: true)
        #expect(try api.listSnapshots(dir: absent.path).isEmpty)
    }
}

// ── Destination : iCloud d'abord, local en repli ──────────────────────────

@Suite("Sauvegarde automatique — destination")
struct LibrarySnapshotsDestinationTests {

    /// La garantie qui compte : quelle que soit la disponibilité d'iCloud,
    /// `destination()` rend un dossier où l'on peut RÉELLEMENT écrire.
    /// Refuser de sauvegarder quand iCloud manque punirait précisément ceux
    /// qui n'ont pas de sauvegarde iCloud.
    @Test func destinationIsAlwaysWritable() throws {
        let (dossier, _) = LibrarySnapshots.destination()
        let temoin = dossier.appendingPathComponent("ecriture_\(UUID().uuidString).txt")
        try "ok".write(to: temoin, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: temoin.path))
        try? FileManager.default.removeItem(at: temoin)
    }

    /// Le repli local doit exister par lui-même, indépendamment d'iCloud.
    @Test func localFallbackSitsBesideTheDatabase() throws {
        let local = try LibrarySnapshots.localDirectory()
        #expect(local.lastPathComponent == "Snapshots")
        // Frère de pinkha.db, pas enfant : c'est ce voisinage qui a survécu
        // lors de la perte du 2026-09-02.
        let parent = local.deletingLastPathComponent()
        #expect(parent.lastPathComponent == "Pinkha")
        #expect(FileManager.default.fileExists(atPath: local.path))
    }

    /// Un instantané écrit à la destination réelle doit se relire seul —
    /// c'est vrai dans iCloud comme en local, et c'est le seul critère.
    @Test func snapshotAtTheRealDestinationReopens() throws {
        let db = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_dest_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: db) }
        let api = try PinkhaApi(dbPath: db.path)
        _ = try api.createLeaf(title: "Vers la destination réelle")

        let (dossier, _) = LibrarySnapshots.destination()
        let chemin = try api.snapshotLibrary(dir: dossier.path, keep: LibrarySnapshots.keep)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: chemin)) }

        let restaure = try PinkhaApi(dbPath: chemin)
        #expect(try restaure.listLeaves().map(\.titlePlain) == ["Vers la destination réelle"])
    }
}
