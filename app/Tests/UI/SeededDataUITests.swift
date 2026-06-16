import XCTest

// UI tests using pre-seeded data via --ui-test-data
// (avoids typeText, which is flaky on the iOS 26 simulator).

final class SeededDataUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchWithSeed() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-data"]
        app.launch()
        return app
    }

    func testSeededLeavesAppearInList() {
        let app = launchWithSeed()
        XCTAssertTrue(app.staticTexts["Seeded Note 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Seeded Note 2"].exists)
    }

    func testTapSeededLeafOpensEditor() {
        let app = launchWithSeed()
        let row = app.staticTexts["Seeded Note 1"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        // Once in the editor, "New block" (AddBlockButton label) must appear.
        XCTAssertTrue(app.staticTexts["New block"].waitForExistence(timeout: 5))
    }

    func testNavigationBackReturnsToList() {
        let app = launchWithSeed()
        let row = app.staticTexts["Seeded Note 1"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["New block"].waitForExistence(timeout: 5))
        // Native back button of NavigationStack inside the Notes tab.
        app.navigationBars.buttons.firstMatch.tap()
        // After returning to the Notes tab the greeting is visible.
        let greetings = ["Good morning.", "Good afternoon.", "Good evening."]
        let predicate = NSPredicate(format: "label IN %@", greetings)
        XCTAssertTrue(app.staticTexts.element(matching: predicate).waitForExistence(timeout: 3))
    }

    func testFabRemainsVisibleOnHome() {
        let app = launchWithSeed()
        let fab = app.buttons["createLeafFAB"]
        XCTAssertTrue(fab.waitForExistence(timeout: 3))
        XCTAssertTrue(fab.isHittable)
    }
}
