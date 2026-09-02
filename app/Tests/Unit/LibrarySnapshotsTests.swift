import Testing
import Foundation
@testable import PinkhaCore

// La décision « faut-il sauvegarder maintenant ? » est la seule logique de
// ce module, et c'est celle qui doit être juste : trop souvent elle coûte du
// disque et de la batterie, trop rarement elle laisse un trou.
@Suite("Sauvegarde automatique — cadence")
struct LibrarySnapshotsTests {

    private let maintenant = Date(timeIntervalSince1970: 1_756_800_000)

    /// Jamais sauvegardé : il faut le faire tout de suite, sans attendre un
    /// premier intervalle. C'est précisément le cas d'un nouvel utilisateur,
    /// donc de quelqu'un qui n'a encore aucune copie.
    @Test func runsImmediatelyWhenNeverRun() {
        #expect(LibrarySnapshots.shouldRun(last: nil, now: maintenant))
    }

    @Test func waitsUntilTheIntervalHasElapsed() {
        let ilYAUneHeure = maintenant.addingTimeInterval(-3600)
        #expect(!LibrarySnapshots.shouldRun(last: ilYAUneHeure, now: maintenant))
    }

    @Test func runsOnceTheIntervalHasElapsed() {
        let ilYASeptHeures = maintenant.addingTimeInterval(-7 * 3600)
        #expect(LibrarySnapshots.shouldRun(last: ilYASeptHeures, now: maintenant))
    }

    /// Pile à l'échéance, on sauvegarde — un intervalle « au moins » et non
    /// « strictement plus que » évite de glisser d'un tour à chaque fois.
    @Test func runsExactlyAtTheBoundary() {
        let pileAlHeure = maintenant.addingTimeInterval(-LibrarySnapshots.interval)
        #expect(LibrarySnapshots.shouldRun(last: pileAlHeure, now: maintenant))
    }

    /// Une date de dernière sauvegarde dans le futur signale une horloge qui
    /// a reculé — changement de fuseau, correction réseau. Refuser d'agir
    /// laisserait l'utilisateur sans copie jusqu'à ce que le temps rattrape.
    @Test func aClockThatWentBackwardsDoesNotBlockBackups() {
        let dansLeFutur = maintenant.addingTimeInterval(48 * 3600)
        #expect(LibrarySnapshots.shouldRun(last: dansLeFutur, now: maintenant))
    }

    /// Sept copies couvrent une semaine de dégâts silencieux : assez pour
    /// s'apercevoir du problème avant que la dernière copie saine ne parte.
    @Test func keepsAWeekOfHistory() {
        #expect(LibrarySnapshots.keep == 7)
        #expect(LibrarySnapshots.interval == 6 * 3600)
    }
}
