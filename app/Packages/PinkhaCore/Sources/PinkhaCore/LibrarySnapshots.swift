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

    /// Intervalle appliqué quand le dernier instantané est resté en LOCAL
    /// alors qu'iCloud était visé.
    ///
    /// `url(forUbiquityContainerIdentifier:)` rend `nil` tant qu'iOS n'a pas
    /// fini de mettre le conteneur à disposition — ce qui est justement le
    /// cas au premier lancement après une installation. Sans ce
    /// raccourcissement, cet échec passager enfermerait l'utilisateur en
    /// sauvegarde locale pendant six heures, alors que le conteneur devient
    /// disponible quelques secondes plus tard. Constaté sur appareil.
    public static let retryInterval: TimeInterval = 15 * 60

    private static let derniereCleUserDefaults = "pinkha.snapshot.lastRun"
    private static let derniereDestinationCleUserDefaults = "pinkha.snapshot.lastWentToCloud"

    /// Où les instantanés sont écrits, et si c'est dans iCloud.
    ///
    /// iCloud Drive d'abord, disque local en repli. Le repli n'est pas une
    /// précaution de style : `url(forUbiquityContainerIdentifier:)` renvoie
    /// `nil` quand l'utilisateur n'est pas connecté à iCloud, quand il a
    /// désactivé iCloud Drive pour l'app, ou quand la build n'a pas les
    /// droits — trois situations parfaitement ordinaires. Refuser de
    /// sauvegarder dans ces cas-là punirait précisément ceux qui n'ont pas
    /// de sauvegarde iCloud, c'est-à-dire ceux qui en ont le plus besoin.
    ///
    /// - Important: appel bloquant (il interroge le démon iCloud). Ce type
    ///   n'est pas `@MainActor` pour cette raison.
    public static func destination() -> (url: URL, dansICloud: Bool) {
        if let cloud = cloudDirectory() { return (cloud, true) }
        // Le local est le dernier rempart : s'il échoue lui aussi, on renvoie
        // quand même le chemin et c'est l'écriture qui signalera l'erreur,
        // avec un message utile.
        return ((try? localDirectory()) ?? fallbackDirectory(), false)
    }

    /// `<conteneur iCloud>/Documents/Snapshots/`.
    ///
    /// Sous `Documents/` volontairement : c'est ce qui rend le dossier
    /// visible dans l'app Fichiers, donc récupérable par l'utilisateur
    /// depuis n'importe quel appareil, sans passer par pinkha. Une
    /// sauvegarde qu'on ne peut atteindre que depuis l'app qui a perdu les
    /// données ne vaut pas grand-chose.
    static func cloudDirectory() -> URL? {
        guard let conteneur = FileManager.default.url(forUbiquityContainerIdentifier: nil)
        else { return nil }
        let dir = conteneur
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Snapshots", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            Observability.capture(error)
            return nil
        }
    }

    /// `Application Support/Pinkha/Snapshots/`, le repli local.
    ///
    /// Volontairement à CÔTÉ de `pinkha.db`, pas dedans. Lors de la perte du
    /// 2026-09-02, `pinkha.db` a disparu tandis que le dossier frère
    /// `Covers/` est resté intact — un instantané rangé en voisin aurait
    /// donc survécu. Ce n'est pas une preuve, mais c'est la seule
    /// observation dont on dispose, et elle est gratuite à suivre.
    public static func localDirectory() throws -> URL {
        let dir = try DatabaseLocation.directory()
            .appendingPathComponent("Snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Dernier recours quand même `Application Support` est inaccessible.
    private static func fallbackDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PinkhaSnapshots", isDirectory: true)
    }

    /// Décide s'il est temps d'écrire, à partir de la date du dernier
    /// instantané. Fonction pure — c'est elle qui est testée, pas l'horloge.
    public static func shouldRun(last: Date?,
                                 now: Date,
                                 wentToCloud: Bool = true,
                                 interval: TimeInterval = interval) -> Bool {
        guard let last else { return true }   // jamais sauvegardé : maintenant.
        // Resté en local alors qu'on visait iCloud : on repasse bien plus
        // tôt, pour rattraper dès que le conteneur devient disponible.
        let attente = wentToCloud ? interval : min(interval, retryInterval)
        // Une date future signale une horloge qui a reculé (changement de
        // fuseau, correction réseau). Refuser d'agir laisserait alors
        // l'utilisateur sans sauvegarde jusqu'à ce que le temps rattrape :
        // on préfère un instantané de trop.
        if last > now { return true }
        return now.timeIntervalSince(last) >= attente
    }

    /// Écrit un instantané si l'intervalle est écoulé. Ne lève jamais :
    /// une sauvegarde qui échoue ne doit pas empêcher l'app de fonctionner,
    /// mais elle est signalée à l'observabilité pour ne pas échouer en
    /// silence pendant des mois.
    @discardableResult
    public static func runIfDue(api: PinkhaApi, now: Date = Date()) -> Bool {
        let defaults = UserDefaults.standard
        let derniere = defaults.object(forKey: derniereCleUserDefaults) as? Date
        guard shouldRun(last: derniere, now: now, wentToCloud: lastRunWentToCloud)
        else { return false }

        let (dir, dansICloud) = destination()
        do {
            _ = try api.snapshotLibrary(dir: dir.path, keep: keep)
            defaults.set(now, forKey: derniereCleUserDefaults)
            defaults.set(dansICloud, forKey: derniereDestinationCleUserDefaults)
            return true
        } catch {
            Observability.capture(error)
            return false
        }
    }

    /// Demande à iOS de préparer le conteneur iCloud, sans rien en faire.
    ///
    /// À appeler tôt, hors du fil principal. Le premier accès au conteneur
    /// est ce qui déclenche sa mise à disposition ; s'en remettre au premier
    /// instantané, c'est garantir que celui-là tombera en local.
    public static func warmUpCloudContainer() {
        _ = FileManager.default.url(forUbiquityContainerIdentifier: nil)
    }

    /// Date du dernier instantané réussi, pour l'afficher dans les réglages.
    public static var lastRun: Date? {
        UserDefaults.standard.object(forKey: derniereCleUserDefaults) as? Date
    }

    /// Le dernier instantané est-il parti dans iCloud ? L'utilisateur doit
    /// pouvoir le savoir : « sauvegardé » sur le seul appareil qui peut
    /// tomber en panne n'a pas le même sens que « sauvegardé ailleurs ».
    public static var lastRunWentToCloud: Bool {
        UserDefaults.standard.bool(forKey: derniereDestinationCleUserDefaults)
    }
}
