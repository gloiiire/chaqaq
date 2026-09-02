import Testing
import Foundation
import PinkhaFFI
@testable import PinkhaCore

// Le test qui compte vraiment : une archive doit se relire SEULE.
// Une sauvegarde qu'on ne peut pas rouvrir n'est pas une sauvegarde.
@Suite("Export de la bibliothèque — aller-retour réel")
struct LibraryExportPersistenceTests {

    private func makeApi() throws -> (PinkhaApi, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinkha_export_\(UUID().uuidString).db")
        return (try PinkhaApi(dbPath: url.path), url)
    }

    private func cleanup(_ url: URL) {
        for suffixe in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: url.path + suffixe))
        }
    }

    @Test func exportedDatabaseReopensOnItsOwn() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        _ = try api.createLeaf(title: "Une note à ne pas perdre")
        _ = try api.createLeaf(title: "Une seconde")

        let copie = FileManager.default.temporaryDirectory
            .appendingPathComponent("copie_\(UUID().uuidString).db")
        defer { cleanup(copie) }

        let octets = try api.exportLibrary(destPath: copie.path)
        #expect(octets > 0)
        #expect(FileManager.default.fileExists(atPath: copie.path))

        let restaure = try PinkhaApi(dbPath: copie.path)
        let titres = try restaure.listLeaves().map(\.titlePlain).sorted()
        #expect(titres == ["Une note à ne pas perdre", "Une seconde"])
    }

    /// L'archive complète : base + couvertures + mode d'emploi, en un fichier.
    @Test func archiveIsASingleNonEmptyFile() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        _ = try api.createLeaf(title: "Contenu")

        let archive = try LibraryExport.makeArchive(api: api)
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }

        #expect(archive.pathExtension == "zip")
        #expect(FileManager.default.fileExists(atPath: archive.path))
        let taille = (try FileManager.default
            .attributesOfItem(atPath: archive.path)[.size] as? Int) ?? 0
        #expect(taille > 0, "une archive vide ne protège de rien")
        #expect(archive.lastPathComponent.hasPrefix("Pinkha "))
    }

    /// Exporter deux fois d'affilée est le cas normal — l'utilisateur
    /// sauvegarde régulièrement. Aucune des deux ne doit échouer.
    @Test func exportingTwiceInARowBothSucceed() throws {
        let (api, url) = try makeApi(); defer { cleanup(url) }
        _ = try api.createLeaf(title: "Deux fois")

        for _ in 0..<2 {
            let archive = try LibraryExport.makeArchive(api: api)
            #expect(FileManager.default.fileExists(atPath: archive.path))
            try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
        }
    }
}
