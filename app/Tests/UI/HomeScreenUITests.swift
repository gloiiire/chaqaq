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
        // The greeting is the navigationTitle of the Library root.
        // iOS 26 XCUITest subscripts (`app.staticTexts["X"]`) match the
        // accessibilityIdentifier, not the label — use a label predicate
        // and search the broader hierarchy.
        let greetings = ["Good morning.", "Good afternoon.", "Good evening."]
        let predicate = NSPredicate(format: "label IN %@", greetings)
        let header = app.staticTexts.element(matching: predicate)
        XCTAssertTrue(header.waitForExistence(timeout: 8))
    }

    func testFloatingButtonOpensCreateSheet() {
        let app = XCUIApplication()
        app.launch()
        // The "new note" icon lives inside the CreateBubble accessory
        // docked in `tabViewBottomAccessory`. Its accessibilityIdentifier
        // bridges the test to the new bubble architecture.
        let fab = app.buttons["createLeafFAB"]
        XCTAssertTrue(fab.waitForExistence(timeout: 5))
        fab.tap()
        // The creation sheet shows "New Leaf" as its navigationTitle.
        XCTAssertTrue(app.navigationBars["New Leaf"].waitForExistence(timeout: 3))
    }

    func testCancelCreateSheetClosesIt() {
        let app = XCUIApplication()
        app.launch()
        let fab = app.buttons["createLeafFAB"]
        XCTAssertTrue(fab.waitForExistence(timeout: 5))
        fab.tap()
        XCTAssertTrue(app.navigationBars["New Leaf"].waitForExistence(timeout: 3))
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 2))
        cancel.tap()
        XCTAssertFalse(app.navigationBars["New Leaf"].waitForExistence(timeout: 2))
    }
}

private extension XCUIElementQuery {
    var lastMatch: XCUIElement { element(boundBy: count - 1) }
}

// iOS 26 XCUITest changed subscript behavior: `app.staticTexts["X"]` now
// matches by accessibilityIdentifier only, no longer by label/value. Tests
// that want to find SwiftUI `Text("X")` elements (which auto-derive their
// label from the string but have no identifier) must use label predicates.
extension XCUIElementQuery {
    func byLabel(_ label: String) -> XCUIElement {
        element(matching: NSPredicate(format: "label == %@", label))
    }
    func byLabelContaining(_ fragment: String) -> XCUIElement {
        element(matching: NSPredicate(format: "label CONTAINS %@", fragment))
    }
}
