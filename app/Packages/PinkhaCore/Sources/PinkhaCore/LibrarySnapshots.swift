import Foundation
import PinkhaFFI

// ── Sauvegarde automatique ────────────────────────────────────────────────
//
// L'export manuel protège ceux qui y pensent. Celui-ci protège les autres —
// c'est-à-dire tout le monde, le jour où ça arrive. La perte du 2026-09-02
// s'est produite pendant la nuit, sans fausse manœuvre : aucune protection
// exigeant une action volontaire n'aurait changé quoi que ce soit.

/// Écrit périodiquement un instantané horodaté de la bibliothèque et n'en
/// conserve qu'un petit nombre.
///
/// Volontairement PAS `@MainActor` : l'écriture est bloquante (quelques
/// centaines de millisecondes sur une grosse bibliothèque) et doit se faire
/// hors du fil principal. `UserDefaults` est sûr entre fils, et le reste
/// n'est que du système de fichiers.
public enum LibrarySnapshots {

    /// Nombre d'instantanés conservés. Sept couvre une semaine de dégâts
    /// silencieux — assez pour qu'on s'aperçoive du problème avant que la
    /// dernière copie saine ne soit écrasée.
    public static let keep: UInt32 = 7

    /// Intervalle minimal entre deux instantanés.
    ///
    /// Six heures est un compromis mesuré : un `VACUUM INTO` sur une grosse
    /// bibliothèque coûte quelques centaines de millisecondes et autant
    /// d'espace disque qu'une copie, donc en faire un à chaque passage en
    /// arrière-plan serait coûteux pour rien. Six heures plafonne la perte
    /// possible à une demi-journée d'écriture.
    public static let interval: TimeInterval = 6 * 3600

    private static let derniereCleUserDefaults = "pinkha.snapshot.lastRun"

    /// Dossier des instantanés : `Application Support/Pinkha/Snapshots/`.
    ///
    /// Volontairement à CÔTÉ de `pinkha.db`, pas dedans. Lors de la perte du
    /// 2026-09-02, `pinkha.db` a disparu tandis que le dossier frère
    /// `Covers/` est resté intact — un instantané rangé en voisin aurait
    /// donc survécu. Ce n'est pas une preuve, mais c'est la seule
    /// observation dont on dispose, et elle est gratuite à suivre.
    public static func directory() throws -> URL {
        let dir = try DatabaseLocation.directory()
            .appendingPathComponent("Snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Décide s'il est temps d'écrire, à partir de la date du dernier
    /// instantané. Fonction pure — c'est elle qui est testée, pas l'horloge.
    public static func shouldRun(last: Date?, now: Date, interval: TimeInterval = interval) -> Bool {
        guard let last else { return true }   // jamais sauvegardé : maintenant.
        // Une date future signale une horloge qui a reculé (changement de
        // fuseau, correction réseau). Refuser d'agir laisserait alors
        // l'utilisateur sans sauvegarde jusqu'à ce que le temps rattrape :
        // on préfère un instantané de trop.
        if last > now { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// Écrit un instantané si l'intervalle est écoulé. Ne lève jamais :
    /// une sauvegarde qui échoue ne doit pas empêcher l'app de fonctionner,
    /// mais elle est signalée à l'observabilité pour ne pas échouer en
    /// silence pendant des mois.
    @discardableResult
    public static func runIfDue(api: PinkhaApi, now: Date = Date()) -> Bool {
        let defaults = UserDefaults.standard
        let derniere = defaults.object(forKey: derniereCleUserDefaults) as? Date
        guard shouldRun(last: derniere, now: now) else { return false }

        do {
            let dir = try directory()
            _ = try api.snapshotLibrary(dir: dir.path, keep: keep)
            defaults.set(now, forKey: derniereCleUserDefaults)
            return true
        } catch {
            Observability.capture(error)
            return false
        }
    }

    /// Date du dernier instantané réussi, pour l'afficher dans les réglages.
    public static var lastRun: Date? {
        UserDefaults.standard.object(forKey: derniereCleUserDefaults) as? Date
    }
}
