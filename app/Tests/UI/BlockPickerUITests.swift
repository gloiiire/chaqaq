import XCTest

// End-to-end flow through the block picker from a seeded leaf.

final class BlockPickerUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openSeededDoc() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-data"]
        app.launch()
        let row = app.staticTexts.byLabel("Seeded Note 1")
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        XCTAssertTrue(app.staticTexts.byLabel("New block").waitForExistence(timeout: 8))
        return app
    }

    func testTapAddBlockOpensPicker() {
        let app = openSeededDoc()
        app.staticTexts.byLabel("New block").tap()
        XCTAssertTrue(app.staticTexts.byLabel("Add a block").waitForExistence(timeout: 3))
    }

    func testPickerShowsAllBlockTypes() {
        let app = openSeededDoc()
        app.staticTexts.byLabel("New block").tap()
        XCTAssertTrue(app.staticTexts.byLabel("Add a block").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.byLabel("Text").exists)
        XCTAssertTrue(app.staticTexts.byLabel("Title 1").exists)
        XCTAssertTrue(app.staticTexts.byLabel("To do").exists)
        XCTAssertTrue(app.staticTexts.byLabel("Divider").exists)
    }

    func testPickerCancelClosesIt() {
        let app = openSeededDoc()
        app.staticTexts.byLabel("New block").tap()
        XCTAssertTrue(app.staticTexts.byLabel("Add a block").waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.staticTexts.byLabel("Add a block").waitForExistence(timeout: 1))
    }
}
