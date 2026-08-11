import XCTest

// Une leaf ouverte doit laisser l'appareil au repos.
//
// Ce test existe à cause d'un bug qui a coûté une journée : l'observateur
// `NSUndoManagerCheckpoint` créait un `Task` à chaque notification. Créer
// une tâche réveille la boucle d'exécution, et une boucle réveillée fait
// émettre à `UndoManager` un nouveau checkpoint — cycle auto-entretenu à
// 100 % d'un coeur, en permanence, sans aucune interaction.
//
// Les symptômes ne ressemblaient pas à leur cause : l'appareil chauffait,
// l'édition saccadait, et changer d'onglet depuis une leaf figeait l'app.
// Trois signalements distincts, un seul bug. Rien dans les tests
// fonctionnels ne pouvait l'attraper — le comportement était correct, seul
// le coût ne l'était pas.
//
// Mesures de référence sur simulateur, leaf seedée vide :
//   avec le bug   ~100 % de CPU au repos
//   après         ~0,7 %

final class LeafIdleCPUTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testOpenLeafStaysIdle() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-data"]

        // `XCTCPUMetric` attribue la consommation à l'app mesurée. La
        // fenêtre d'inactivité doit être assez longue pour qu'une boucle
        // s'y installe : à 60 Hz, quelques secondes suffisent largement.
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(metrics: [XCTCPUMetric(application: app)], options: options) {
            app.launch()
            let row = app.staticTexts.byLabel("Seeded Leaf 1")
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.tap()
            XCTAssertTrue(app.staticTexts.byLabel("New block").waitForExistence(timeout: 10))
            Thread.sleep(forTimeInterval: 8)
            app.terminate()
        }
    }
}
