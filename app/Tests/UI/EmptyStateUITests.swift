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
        XCTAssertTrue(app.staticTexts["No notes"].waitForExistence(timeout: 5))
    }

    func testFabStillPresentInEmptyState() {
        let app = launchClean()
        let fab = app.buttons["createDocumentFAB"]
        XCTAssertTrue(fab.waitForExistence(timeout: 5))
        XCTAssertTrue(fab.isHittable)
    }

    func testEmptyStateHasHelpText() {
        let app = launchClean()
        // The help text starts with "Tap the button…"
        let predicate = NSPredicate(format: "label CONTAINS %@", "Tap the button")
        let helpText = app.staticTexts.element(matching: predicate)
        XCTAssertTrue(helpText.waitForExistence(timeout: 5))
    }
}
