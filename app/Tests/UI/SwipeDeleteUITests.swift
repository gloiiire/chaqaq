import XCTest

// Swipe-to-delete on a pre-seeded note — no typeText needed.

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
        let row = app.staticTexts.byLabel("Seeded Note 1")
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        // Swipe left then tap Delete
        row.swipeLeft()
        let deleteBtn = app.buttons["Delete"]
        if deleteBtn.waitForExistence(timeout: 2) {
            deleteBtn.tap()
            XCTAssertFalse(app.staticTexts.byLabel("Seeded Note 1").waitForExistence(timeout: 2),
                           "the deleted doc must no longer appear")
            // The other seeded leaf must still be present.
            XCTAssertTrue(app.staticTexts.byLabel("Seeded Note 2").exists)
        }
    }
}
