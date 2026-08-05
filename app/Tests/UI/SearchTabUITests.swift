import XCTest

// The Search tab's detached bubble, end-to-end.
//
// iOS 27 turned the detached search bubble into the "prominent tab"
// treatment and gated it: `UITabBarController.prominentTabIdentifier` only
// falls back to the search tab when that tab's `automaticallyActivatesSearch`
// is true, and `UISearchTab.h` documents that flag's default as NO. SwiftUI's
// spelling of setting it to YES is `.tabViewSearchActivation(.searchTabSelection)`.
//
// The layout itself is not assertable from XCUITest — there is no API for
// "is this button outside the tab bar capsule". What *is* assertable is the
// behaviour the same flag switches on: selecting the tab focuses the field,
// and cancelling restores the previous tab. Those are the observable proxy
// for the flag being set, so if they hold, the bubble is detached.

final class SearchTabUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The search tab is a `UISearchTab`, so its label is system-localized
    /// rather than something we set. Once it receives the prominent
    /// treatment it is no longer a descendant of the tab bar element, so
    /// look in both scopes — that fallback is precisely what makes this
    /// helper survive the change under test.
    private func searchTab(_ app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "label == %@", "Search")
        let inBar = app.tabBars.buttons.element(matching: predicate)
        return inBar.exists ? inBar : app.buttons.element(matching: predicate)
    }

    /// Dismisses the active search. Two conventions matter here: subscripts
    /// match `accessibilityIdentifier` and never the label, and the system
    /// labels this button "Close" — not "Cancel", which is what the pre-iOS-26
    /// search bar used and what a reasonable guess would reach for.
    private func closeSearchButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.element(matching: NSPredicate(format: "label == %@", "Close"))
    }

    func testSelectingSearchTabFocusesTheField() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-data"]
        app.launch()

        let tab = searchTab(app)
        XCTAssertTrue(tab.waitForExistence(timeout: 8), "search tab not reachable")
        tab.tap()

        // Auto-activation is the mechanism behind the detached bubble, so a
        // keyboard here is the closest thing to asserting the layout.
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "field did not auto-focus — the search tab is not prominent")
    }

    /// `.searchTabSelection` deselects the search tab on cancel and restores
    /// the previously selected one. Guards against stranding the user on a
    /// blank search screen.
    func testCancellingSearchRestoresThePreviousTab() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-data"]
        app.launch()

        let books = app.tabBars.buttons.element(
            matching: NSPredicate(format: "label == %@", "Books"))
        XCTAssertTrue(books.waitForExistence(timeout: 8))
        books.tap()

        searchTab(app).tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))

        closeSearchButton(app).tap()
        XCTAssertTrue(books.waitForExistence(timeout: 5))
    }

    /// The detached bubble sits next to the create accessory. This is the
    /// regression canary for that neighbourhood: `LeafView+Toolbar` hard-codes
    /// offsets off `tabViewBottomAccessoryPlacement`, so a layout shift here
    /// moves the leaf editor's toolbar too.
    func testCreateBubbleSurvivesASearchRoundTrip() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-data"]
        app.launch()

        let fab = app.buttons["createLeafFAB"]
        XCTAssertTrue(fab.waitForExistence(timeout: 8))

        searchTab(app).tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        closeSearchButton(app).tap()

        XCTAssertTrue(fab.waitForExistence(timeout: 5))
        XCTAssertTrue(fab.isHittable, "create bubble no longer tappable")
    }
}
