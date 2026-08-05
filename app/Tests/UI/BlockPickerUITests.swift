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
        let row = app.staticTexts.byLabel("Seeded Leaf 1")
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

    /// Scrolls the picker until `label` is on screen.
    ///
    /// The picker's list is lazy, so a plain `.exists` only sees the rows
    /// materialised at the current scroll offset — which is why asserting
    /// every type up front failed for the entries further down.
    private func pickerRow(_ app: XCUIApplication, _ label: String) -> Bool {
        let row = app.staticTexts.byLabel(label)
        for _ in 0..<4 {
            if row.exists { return true }
            app.swipeUp()
        }
        return row.exists
    }

    func testPickerShowsAllBlockTypes() {
        let app = openSeededDoc()
        app.staticTexts.byLabel("New block").tap()
        XCTAssertTrue(app.staticTexts.byLabel("Add a block").waitForExistence(timeout: 3))
        for label in ["Text", "Title 1", "To do", "Divider"] {
            XCTAssertTrue(pickerRow(app, label), "block type '\(label)' not offered")
        }
    }

    func testPickerCancelClosesIt() {
        let app = openSeededDoc()
        app.staticTexts.byLabel("New block").tap()
        XCTAssertTrue(app.staticTexts.byLabel("Add a block").waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.staticTexts.byLabel("Add a block").waitForExistence(timeout: 1))
    }
}
