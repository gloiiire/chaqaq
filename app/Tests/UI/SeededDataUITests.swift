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

    func testSeededDocumentsAppearInList() {
        let app = launchWithSeed()
        XCTAssertTrue(app.staticTexts["Seeded Note 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Seeded Note 2"].exists)
    }

    func testTapSeededDocumentOpensEditor() {
        let app = launchWithSeed()
        let row = app.staticTexts["Seeded Note 1"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        // Once in the editor, "Nouveau bloc" (AddBlockButton label) must appear.
        XCTAssertTrue(app.staticTexts["Nouveau bloc"].waitForExistence(timeout: 5))
    }

    func testNavigationBackReturnsToList() {
        let app = launchWithSeed()
        let row = app.staticTexts["Seeded Note 1"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["Nouveau bloc"].waitForExistence(timeout: 5))
        // Native back button of NavigationStack
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["pinkha"].waitForExistence(timeout: 3))
    }

    func testFabRemainsVisibleOnHome() {
        let app = launchWithSeed()
        let fab = app.buttons["createDocumentFAB"]
        XCTAssertTrue(fab.waitForExistence(timeout: 3))
        XCTAssertTrue(fab.isHittable)
    }
}
