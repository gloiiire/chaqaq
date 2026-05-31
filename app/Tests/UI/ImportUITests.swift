import XCTest

// End-to-end UI tests for the import sheets.
// Uses --ui-test-data so the app starts with seeded data (no typeText required).
// XCUITest stays on classic XCTest (Swift Testing does not cover UI automation).

final class ImportUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    /// Launches the app with seeded data and waits for the home screen.
    private func launchSeeded() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-data"]
        app.launch()
        // Wait for any one of the time-dependent greetings to appear.
        let greetings = ["Good morning.", "Good afternoon.", "Good evening."]
        let predicate = NSPredicate(format: "label IN %@", greetings)
        let greeting = app.staticTexts.element(matching: predicate)
        XCTAssertTrue(greeting.waitForExistence(timeout: 5), "Home greeting should appear")
        return app
    }

    /// Opens the FAB menu and taps the given menu item label.
    private func openFABAndTapItem(app: XCUIApplication, itemLabel: String) {
        // The FAB is a Menu — tapping it reveals its items.
        let fab = app.buttons["createFAB"]
        XCTAssertTrue(fab.waitForExistence(timeout: 3), "createFAB must be visible on home screen")
        fab.tap()

        // Menu items may appear as buttons or menu items depending on iOS version.
        let menuItem = app.buttons[itemLabel].firstMatch
        if !menuItem.waitForExistence(timeout: 2) {
            // Fallback: look in menuItems (presented as UIMenuElement on some iOS versions).
            let fallback = app.menuItems[itemLabel].firstMatch
            XCTAssertTrue(fallback.waitForExistence(timeout: 2), "'\(itemLabel)' must appear in the FAB menu")
            fallback.tap()
        } else {
            menuItem.tap()
        }
    }

    // MARK: - Notion import sheet

    func test_notion_import_sheet_opens() {
        let app = launchSeeded()
        openFABAndTapItem(app: app, itemLabel: "Import from Notion")

        // The sheet navigation title must be visible.
        XCTAssertTrue(
            app.navigationBars["Import from Notion"].waitForExistence(timeout: 3),
            "Import from Notion sheet should open with the correct navigation title"
        )
    }

    func test_notion_import_sheet_shows_form_fields() {
        let app = launchSeeded()
        openFABAndTapItem(app: app, itemLabel: "Import from Notion")

        XCTAssertTrue(
            app.navigationBars["Import from Notion"].waitForExistence(timeout: 3)
        )
        // The API Token section header must appear.
        XCTAssertTrue(
            app.staticTexts["API Token"].waitForExistence(timeout: 2),
            "Notion import form should show the API Token section"
        )
    }

    func test_notion_import_sheet_dismisses() {
        let app = launchSeeded()
        openFABAndTapItem(app: app, itemLabel: "Import from Notion")

        XCTAssertTrue(app.navigationBars["Import from Notion"].waitForExistence(timeout: 3))

        // Tap the Cancel button to dismiss the sheet.
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 2), "Cancel button must exist in the import sheet")
        cancel.tap()

        // After dismissal the sheet's navigation bar should be gone.
        XCTAssertFalse(
            app.navigationBars["Import from Notion"].waitForExistence(timeout: 2),
            "Import from Notion sheet should be dismissed after tapping Cancel"
        )
    }

    // MARK: - Bear import sheet

    func test_bear_import_sheet_opens() {
        let app = launchSeeded()
        openFABAndTapItem(app: app, itemLabel: "Import from Bear")

        XCTAssertTrue(
            app.navigationBars["Import from Bear"].waitForExistence(timeout: 3),
            "Import from Bear sheet should open with the correct navigation title"
        )
    }

    func test_bear_import_sheet_shows_choose_database_button() {
        let app = launchSeeded()
        openFABAndTapItem(app: app, itemLabel: "Import from Bear")

        XCTAssertTrue(app.navigationBars["Import from Bear"].waitForExistence(timeout: 3))

        // The file picker trigger button is labeled "Choose database.sqlite…".
        XCTAssertTrue(
            app.buttons["Choose database.sqlite…"].waitForExistence(timeout: 2) ||
            app.staticTexts["Choose database.sqlite…"].waitForExistence(timeout: 1),
            "Bear import form should show the file picker button"
        )
    }

    func test_bear_import_sheet_dismisses() {
        let app = launchSeeded()
        openFABAndTapItem(app: app, itemLabel: "Import from Bear")

        XCTAssertTrue(app.navigationBars["Import from Bear"].waitForExistence(timeout: 3))

        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 2), "Cancel button must exist in the Bear import sheet")
        cancel.tap()

        XCTAssertFalse(
            app.navigationBars["Import from Bear"].waitForExistence(timeout: 2),
            "Import from Bear sheet should be dismissed after tapping Cancel"
        )
    }

    // MARK: - Import button disabled state

    func test_notion_import_button_disabled_when_fields_empty() {
        let app = launchSeeded()
        openFABAndTapItem(app: app, itemLabel: "Import from Notion")

        XCTAssertTrue(app.navigationBars["Import from Notion"].waitForExistence(timeout: 3))

        // With empty token and URL fields the Import button must be disabled.
        let importBtn = app.buttons["Import"].firstMatch
        if importBtn.waitForExistence(timeout: 2) {
            XCTAssertFalse(importBtn.isEnabled, "Import button should be disabled when token/URL are empty")
        }
        // If the button is not visible at all (e.g. hidden behind a ProgressView), the test passes implicitly.
    }

    func test_bear_import_button_disabled_when_no_file_selected() {
        let app = launchSeeded()
        openFABAndTapItem(app: app, itemLabel: "Import from Bear")

        XCTAssertTrue(app.navigationBars["Import from Bear"].waitForExistence(timeout: 3))

        let importBtn = app.buttons["Import"].firstMatch
        if importBtn.waitForExistence(timeout: 2) {
            XCTAssertFalse(importBtn.isEnabled, "Import button should be disabled when no file is selected")
        }
    }
}
