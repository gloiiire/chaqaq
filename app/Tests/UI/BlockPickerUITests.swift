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
        XCTAssertTrue(app.staticTexts["New block"].waitForExistence(timeout: 5))
        return app
    }

    func testTapAddBlockOpensPicker() {
        let app = openSeededDoc()
        // The "New block" button at the bottom of the list.
        app.staticTexts["New block"].tap()
        // The picker displays the title "Add a block".
        XCTAssertTrue(app.staticTexts["Add a block"].waitForExistence(timeout: 3))
    }

    func testPickerShowsAllBlockTypes() {
        let app = openSeededDoc()
        app.staticTexts["New block"].tap()
        XCTAssertTrue(app.staticTexts["Add a block"].waitForExistence(timeout: 3))
        // At least the main block types must be listed.
        XCTAssertTrue(app.staticTexts["Text"].exists || app.cells.staticTexts["Text"].exists)
        XCTAssertTrue(app.staticTexts["Title 1"].exists || app.cells.staticTexts["Title 1"].exists)
        XCTAssertTrue(app.staticTexts["To do"].exists || app.cells.staticTexts["To do"].exists)
        XCTAssertTrue(app.staticTexts["Divider"].exists || app.cells.staticTexts["Divider"].exists)
    }

    func testPickerCancelClosesIt() {
        let app = openSeededDoc()
        app.staticTexts["New block"].tap()
        XCTAssertTrue(app.staticTexts["Add a block"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.staticTexts["Add a block"].waitForExistence(timeout: 1))
    }
}
