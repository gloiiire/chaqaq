import Foundation
import PinkhaFFI

// ── Export de la bibliothèque ─────────────────────────────────────────────
//
// Le 2 septembre 2026, la base d'un appareil réel s'est retrouvée vide du
// jour au lendemain. Sept années d'écrits n'ont survécu que parce qu'une
// copie traînait par hasard sur un simulateur. Ce module existe pour que
// cela ne dépende plus jamais du hasard.

/// Fabrique une archive autonome de toute la bibliothèque : la base plus les
/// images de couverture, dans un seul fichier que l'utilisateur range où il
/// veut.
public enum LibraryExport {

    /// Assemble l'archive et renvoie son emplacement.
    ///
    /// L'appelant est responsable de la présenter (feuille de partage) puis
    /// de nettoyer le dossier temporaire.
    ///
    /// - Note: l'instantané de la base est fait **côté Rust**
    ///   (`VACUUM INTO`), depuis la connexion vivante. Copier `pinkha.db`
    ///   depuis Swift shipperait une base amputée : en mode WAL, la fin des
    ///   écritures validées vit encore dans `pinkha.db-wal`. Ce sont
    ///   précisément les octets les plus récents, donc ceux auxquels
    ///   l'utilisateur tient le plus.
    public static func makeArchive(api: PinkhaApi,
                                   now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let horodatage = Self.stamp(now)

        // Le dossier mis en archive donne son nom à la racine du zip —
        // `.forUploading` conserve le dossier racine, pas seulement son
        // contenu. On le nomme donc pour l'utilisateur, pas pour la machine.
        let travail = fm.temporaryDirectory
            .appendingPathComponent("pinkha-export-\(UUID().uuidString)", isDirectory: true)
        let contenu = travail.appendingPathComponent("Pinkha \(horodatage)", isDirectory: true)
        try fm.createDirectory(at: contenu, withIntermediateDirectories: true)

        let base = contenu.appendingPathComponent("pinkha.db")
        _ = try api.exportLibrary(destPath: base.path)

        // Les couvertures sont des fichiers à part, référencés par nom depuis
        // la base. Une archive sans elles rouvrirait une bibliothèque aux
        // pages nues.
        if let couvertures = try? CoverImageStorage.directory(),
           fm.fileExists(atPath: couvertures.path) {
            try? fm.copyItem(at: couvertures,
                             to: contenu.appendingPathComponent("Covers", isDirectory: true))
        }

        try Self.lisezMoi(horodatage: horodatage)
            .write(to: contenu.appendingPathComponent("LISEZ-MOI.txt"),
                   atomically: true, encoding: .utf8)

        return try Self.zip(contenu, nommee: "Pinkha \(horodatage).zip", dans: travail)
    }

    /// Compresse `dossier` sans dépendance externe.
    ///
    /// `NSFileCoordinator` avec l'intention `.forUploading` produit une
    /// archive zip d'un dossier — c'est le mécanisme que le système utilise
    /// lui-même pour téléverser un paquet. Il écrit dans un emplacement
    /// qu'il choisit et qui n'est valide que le temps du bloc, d'où la copie
    /// vers une destination stable avant d'en sortir.
    private static func zip(_ dossier: URL, nommee nom: String, dans base: URL) throws -> URL {
        let destination = base.appendingPathComponent(nom)
        var erreurCoordination: NSError?
        var erreurCopie: Error?

        NSFileCoordinator().coordinate(readingItemAt: dossier,
                                       options: [.forUploading],
                                       error: &erreurCoordination) { archiveTemporaire in
            do {
                try FileManager.default.copyItem(at: archiveTemporaire, to: destination)
            } catch {
                erreurCopie = error
            }
        }

        if let erreurCoordination { throw erreurCoordination }
        if let erreurCopie { throw erreurCopie }
        return destination
    }

    /// Horodatage lisible et triable, sans caractère interdit dans un nom de
    /// fichier — l'utilisateur va voir ce nom dans Fichiers.
    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH'h'mm"
        return f.string(from: date)
    }

    /// Une archive sans mode d'emploi est une archive qu'on n'ose pas ouvrir
    /// dans deux ans.
    static func lisezMoi(horodatage: String) -> String {
        """
        Sauvegarde Pinkha — \(horodatage)

        Ce dossier contient toute votre bibliothèque :

          pinkha.db   toutes vos feuilles, livres et étagères
          Covers/     les images de couverture

        pinkha.db est une base SQLite standard. N'importe quel lecteur
        SQLite peut l'ouvrir, aujourd'hui comme dans dix ans, même sans
        Pinkha : vos écrits ne dépendent pas de la survie de cette app.

        Pour restaurer, ouvrez cette sauvegarde depuis Pinkha.

        Gardez au moins une copie ailleurs que sur votre téléphone.
        """
    }
}
