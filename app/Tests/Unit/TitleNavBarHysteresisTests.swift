import Testing
import CoreGraphics
@testable import LeafFeature

// Le seuil unique d'origine pouvait osciller : la grandeur comparée
// contient `contentInsets.top`, que la réaction modifie. Ces tests
// verrouillent la zone morte qui rend l'oscillation impossible.
@Suite("Titre dans la barre — zone morte")
struct TitleNavBarHysteresisTests {

    @Test func restsHiddenNearTheTop() {
        #expect(titleShouldEnterNavBar(offset: 0, currently: false) == false)
        #expect(titleShouldEnterNavBar(offset: 59, currently: false) == false)
    }

    @Test func showsOncePastTheUpperThreshold() {
        #expect(titleShouldEnterNavBar(offset: 61, currently: false))
    }

    @Test func staysShownThroughTheDeadBand() {
        // Le coeur du correctif : une fois visible, repasser sous 60 ne
        // le rabat pas — sinon un simple déplacement d'inset rebascule.
        #expect(titleShouldEnterNavBar(offset: 59, currently: true))
        #expect(titleShouldEnterNavBar(offset: 41, currently: true))
    }

    @Test func hidesOnlyBelowTheLowerThreshold() {
        #expect(titleShouldEnterNavBar(offset: 39, currently: true) == false)
    }

    /// Propriété décisive : aucun décalage n'est un point fixe instable.
    /// Réinjecter la sortie comme état d'entrée doit converger en un pas,
    /// pour tout décalage — c'est ce qui interdit la boucle.
    @Test func noOffsetOscillates() {
        for tenths in 0...1200 {
            let offset = CGFloat(tenths) / 10
            for start in [true, false] {
                let once  = titleShouldEnterNavBar(offset: offset, currently: start)
                let twice = titleShouldEnterNavBar(offset: offset, currently: once)
                #expect(once == twice, "oscillation à \(offset) depuis \(start)")
            }
        }
    }
}
