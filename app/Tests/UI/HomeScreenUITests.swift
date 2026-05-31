import XCTest

// End-to-end tests (XCUITest): drives the app as a real user would.
// XCUITest stays on classic XCTest (Swift Testing does not cover UI).

final class HomeScreenUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunchesAndShowsGreeting() {
        let app = XCUIApplication()
        app.launch()
        // One of the three time-dependent greetings must appear.
        let greetings = ["Bonjour.", "Bon après-midi.", "Bonsoir."]
        let predicate = NSPredicate(format: "label IN %@", greetings)
        let header = app.staticTexts.element(matching: predicate)
        XCTAssertTrue(header.waitForExistence(timeout: 5))
    }

    func testFloatingButtonOpensCreateSheet() {
        let app = XCUIApplication()
        app.launch()
        // The home FAB uses the "square.and.pencil" icon — its default accessibilityLabel
        // is sufficient to locate it, or target the button by icon.
        let fab = app.buttons["createDocumentFAB"]
        XCTAssertTrue(fab.waitForExistence(timeout: 3))
        fab.tap()
        // The creation sheet must display "Nouveau document".
        XCTAssertTrue(app.staticTexts["Nouveau document"].waitForExistence(timeout: 3))
    }

    func testCancelCreateSheetClosesIt() {
        let app = XCUIApplication()
        app.launch()
        let fab = app.buttons["createDocumentFAB"]
        XCTAssertTrue(fab.waitForExistence(timeout: 3))
        fab.tap()
        let cancel = app.buttons["Annuler"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 1))
        cancel.tap()
        XCTAssertFalse(app.staticTexts["Nouveau document"].waitForExistence(timeout: 1))
    }
}

private extension XCUIElementQuery {
    var lastMatch: XCUIElement { element(boundBy: count - 1) }
}
