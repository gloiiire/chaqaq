import XCTest

// Reaches the customize-theme sheet and captures it.
//
// The sheet sits behind the leaf's overflow menu, which is a UIKit
// `UIMenu` — ImportUITests already documents that nested overflow menus
// are not reliably automatable on the simulator. So the menu hop is
// replaced by `--ui-test-reader-customize`, which presents the sheet on
// appear; everything before it (tapping a seeded row) is an ordinary,
// reliable list tap.
//
// Without this path the sheet is unreachable by any automated check,
// and its parity with Apple Books could only ever be asserted from
// memory. The attachments let the rendering be compared against the
// reference captures in utilities/docs/books-reference/.

final class ReaderCustomizeSheetUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Appearance is driven by the simulator (`simctl ui booted appearance`)
    /// rather than a launch argument: the confirm button and the sliders
    /// follow the system appearance, so the real thing is what should be
    /// exercised, and it keeps the flag count in the app at one.
    private func openCustomizeSheet() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-data", "--ui-test-reader-customize"]
        app.launch()

        let row = app.staticTexts.byLabel("Seeded Leaf 1")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "seeded leaf never appeared")
        row.tap()
        return app
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The title is the cheapest proof the sheet is actually presented
    /// rather than the screenshot having caught the editor.
    func testCustomizeSheetIsReachableAndRenders() {
        let app = openCustomizeSheet()
        XCTAssertTrue(app.staticTexts["Customize Theme"].waitForExistence(timeout: 10),
                      "customize sheet did not present")
        attach(app, named: "customize-sheet")
    }

    /// §12.6: the "Customize" switch is what gates the four sliders.
    /// They live in the same card as the switch, below it — so flipping
    /// it must reveal them without any other navigation.
    func testCustomizeSwitchRevealsTheSliders() {
        let app = openCustomizeSheet()
        XCTAssertTrue(app.staticTexts["Customize Theme"].waitForExistence(timeout: 10))

        XCTAssertFalse(app.staticTexts["LINE SPACING"].exists,
                       "sliders were visible before the switch was turned on")
        app.switches.element(boundBy: 1).tap()

        XCTAssertTrue(app.staticTexts["LINE SPACING"].waitForExistence(timeout: 3),
                      "the Customize switch did not reveal the sliders")
        for label in ["CHARACTER SPACING", "WORD SPACING", "MARGINS"] {
            XCTAssertTrue(app.staticTexts[label].exists, "missing slider: \(label)")
        }
        attach(app, named: "customize-sliders-on")
    }

    /// Books expands the font list inside the same card instead of
    /// pushing a screen or presenting a sheet. Tapping "Font" must
    /// therefore reveal font names while the sheet's own title stays on
    /// screen — a pushed screen would take the title away.
    func testFontPickerExpandsInPlace() {
        let app = openCustomizeSheet()
        XCTAssertTrue(app.staticTexts["Customize Theme"].waitForExistence(timeout: 10))

        app.staticTexts["Font"].tap()

        XCTAssertTrue(app.staticTexts["Original"].waitForExistence(timeout: 3),
                      "font list did not expand in place")
        XCTAssertTrue(app.staticTexts["Customize Theme"].exists,
                      "sheet title disappeared — the picker pushed or presented "
                      + "instead of expanding inline")
        attach(app, named: "customize-font-expanded")
    }
}
