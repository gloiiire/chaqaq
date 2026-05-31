import XCTest

// End-to-end flow through the block picker from a seeded document.

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
        // The "Nouveau bloc" button at the bottom of the list.
        app.staticTexts["Nouveau bloc"].tap()
        // The picker displays the title "Ajouter un bloc".
        XCTAssertTrue(app.staticTexts["Ajouter un bloc"].waitForExistence(timeout: 3))
    }

    func testPickerShowsAllBlockTypes() {
        let app = openSeededDoc()
        app.staticTexts["Nouveau bloc"].tap()
        XCTAssertTrue(app.staticTexts["Ajouter un bloc"].waitForExistence(timeout: 3))
        // At least the main block types must be listed.
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
