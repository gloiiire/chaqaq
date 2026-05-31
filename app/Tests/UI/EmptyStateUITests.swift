import XCTest

// Verifies the empty state (no documents) — uses --ui-test-clean for an empty DB.

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
        // The help text starts with "Appuie sur le bouton…"
        let predicate = NSPredicate(format: "label CONTAINS %@", "Appuie sur")
        let helpText = app.staticTexts.element(matching: predicate)
        XCTAssertTrue(helpText.waitForExistence(timeout: 5))
    }
}
