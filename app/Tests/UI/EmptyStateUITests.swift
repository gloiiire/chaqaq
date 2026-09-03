import XCTest

// Verifies the empty state (no leaves) — uses --ui-test-clean for an empty DB.

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
        XCTAssertTrue(app.staticTexts.byLabel("No leaves").waitForExistence(timeout: 8))
    }

    func testFabStillPresentInEmptyState() {
        let app = launchClean()
        let fab = app.buttons["createLeafFAB"]
        XCTAssertTrue(fab.waitForExistence(timeout: 5))
        XCTAssertTrue(fab.isHittable)
    }

    func testEmptyStateHasHelpText() {
        let app = launchClean()
        let helpText = app.staticTexts.byLabelContaining("Tap Leaf below")
        XCTAssertTrue(helpText.waitForExistence(timeout: 8))
    }
}
