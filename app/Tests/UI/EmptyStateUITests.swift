import XCTest

// Vérifie l'état vide (aucun document) — utilise --ui-test-clean pour DB vide.

final class EmptyStateUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchClean() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-clean"]
        app.launch()
        return app
    }

    func testEmptyStateShowsHelpMessage() {
        let app = launchClean()
        XCTAssertTrue(app.staticTexts["Aucun document"].waitForExistence(timeout: 5))
    }

    func testFabStillPresentInEmptyState() {
        let app = launchClean()
        let fab = app.buttons["createDocumentFAB"]
        XCTAssertTrue(fab.waitForExistence(timeout: 5))
        XCTAssertTrue(fab.isHittable)
    }

    func testEmptyStateHasHelpText() {
        let app = launchClean()
        // Le texte d'aide commence par "Appuie sur le bouton…"
        let predicate = NSPredicate(format: "label CONTAINS %@", "Appuie sur")
        let helpText = app.staticTexts.element(matching: predicate)
        XCTAssertTrue(helpText.waitForExistence(timeout: 5))
    }
}
