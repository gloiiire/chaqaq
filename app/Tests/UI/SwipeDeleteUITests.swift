import XCTest

// Swipe-to-delete sur une note pré-seedée — pas de typeText nécessaire.

final class SwipeDeleteUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchWithSeed() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-data"]
        app.launch()
        return app
    }

    func testSwipeDeleteRemovesDocFromList() {
        let app = launchWithSeed()
        let row = app.staticTexts["Seeded Note 1"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        // Swipe left puis Supprimer
        row.swipeLeft()
        let deleteBtn = app.buttons["Supprimer"]
        if deleteBtn.waitForExistence(timeout: 2) {
            deleteBtn.tap()
            XCTAssertFalse(app.staticTexts["Seeded Note 1"].waitForExistence(timeout: 2),
                           "le doc supprimé ne doit plus apparaître")
            // L'autre seeded doit toujours être là.
            XCTAssertTrue(app.staticTexts["Seeded Note 2"].exists)
        }
    }
}
