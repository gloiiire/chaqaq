import XCTest

// Flow E2E sur le picker de blocs depuis un doc seedé.

final class BlockPickerUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openSeededDoc() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-data"]
        app.launch()
        let row = app.staticTexts["Seeded Note 1"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["Nouveau bloc"].waitForExistence(timeout: 5))
        return app
    }

    func testTapAddBlockOpensPicker() {
        let app = openSeededDoc()
        // Le bouton "Nouveau bloc" en fin de liste.
        app.staticTexts["Nouveau bloc"].tap()
        // Le picker affiche le titre "Ajouter un bloc".
        XCTAssertTrue(app.staticTexts["Ajouter un bloc"].waitForExistence(timeout: 3))
    }

    func testPickerShowsAllBlockTypes() {
        let app = openSeededDoc()
        app.staticTexts["Nouveau bloc"].tap()
        XCTAssertTrue(app.staticTexts["Ajouter un bloc"].waitForExistence(timeout: 3))
        // Au moins les types principaux doivent être listés.
        XCTAssertTrue(app.staticTexts["Texte"].exists || app.cells.staticTexts["Texte"].exists)
        XCTAssertTrue(app.staticTexts["Titre 1"].exists || app.cells.staticTexts["Titre 1"].exists)
        XCTAssertTrue(app.staticTexts["À faire"].exists || app.cells.staticTexts["À faire"].exists)
        XCTAssertTrue(app.staticTexts["Séparateur"].exists || app.cells.staticTexts["Séparateur"].exists)
    }

    func testPickerCancelClosesIt() {
        let app = openSeededDoc()
        app.staticTexts["Nouveau bloc"].tap()
        XCTAssertTrue(app.staticTexts["Ajouter un bloc"].waitForExistence(timeout: 3))
        app.buttons["Annuler"].tap()
        XCTAssertFalse(app.staticTexts["Ajouter un bloc"].waitForExistence(timeout: 1))
    }
}
