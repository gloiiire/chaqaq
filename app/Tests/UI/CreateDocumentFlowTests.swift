import XCTest

// Flow E2E : créer un document depuis l'accueil et le retrouver dans la liste.

final class CreateDocumentFlowTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCreateThenSeeInList() {
        let app = XCUIApplication()
        app.launch()

        // Ouvre la sheet de création via le FAB d'accueil (square.and.pencil).
        let fab = app.buttons.matching(identifier: "square.and.pencil").firstMatch
        XCTAssertTrue(fab.waitForExistence(timeout: 3))
        fab.tap()

        // Saisie du titre.
        let titleField = app.textFields["Titre du document"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 2))
        titleField.tap()
        let title = "Note de test \(Int.random(in: 1000...9999))"
        titleField.typeText(title)

        // Valide via le bouton checkmark (accessibilityLabel = "Créer").
        let confirm = app.buttons["Créer"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 1))
        confirm.tap()

        // Le document doit apparaître dans la liste.
        let row = app.staticTexts[title]
        XCTAssertTrue(row.waitForExistence(timeout: 3), "le document créé doit apparaître dans la liste")
    }

    func testCancelKeepsListUntouched() {
        let app = XCUIApplication()
        app.launch()

        let fab = app.buttons.matching(identifier: "square.and.pencil").firstMatch
        XCTAssertTrue(fab.waitForExistence(timeout: 3))
        fab.tap()

        // Annule via la croix (accessibilityLabel = "Annuler").
        let cancel = app.buttons["Annuler"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 1))
        cancel.tap()

        // La sheet doit être fermée et le titre "Nouveau document" plus visible.
        XCTAssertFalse(app.staticTexts["Nouveau document"].waitForExistence(timeout: 1))
    }
}
