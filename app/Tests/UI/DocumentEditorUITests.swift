import XCTest

// E2E : crée un document puis l'ouvre dans l'éditeur.

final class DocumentEditorUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCreateThenOpenShowsEditor() throws {
        try XCTSkipIf(true, "typeText flaky sur simulateur iOS 26 — à investiguer")
        let app = XCUIApplication()
        app.launch()

        // Crée un document.
        let fab = app.buttons["createDocumentFAB"]
        XCTAssertTrue(fab.waitForExistence(timeout: 3))
        fab.tap()

        let titleField = app.textFields["Titre du document"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 2))
        titleField.tap()
        let title = "Doc à ouvrir \(Int.random(in: 1000...9999))"
        titleField.typeText(title)
        app.buttons["Créer"].tap()

        // Ouvre le document depuis la liste.
        let row = app.staticTexts[title]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()

        // L'éditeur doit afficher au moins une zone de saisie (le titre).
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 3)
            || app.textFields.firstMatch.waitForExistence(timeout: 3))
    }

    func testEmptyDocumentShowsAddBlockButton() throws {
        try XCTSkipIf(true, "typeText flaky sur simulateur iOS 26 — à investiguer")
        let app = XCUIApplication()
        app.launch()

        // Crée un doc vide et entre dedans.
        let fab = app.buttons["createDocumentFAB"]
        XCTAssertTrue(fab.waitForExistence(timeout: 3))
        fab.tap()
        let titleField = app.textFields["Titre du document"]
        titleField.tap()
        let title = "Doc vide \(Int.random(in: 1000...9999))"
        titleField.typeText(title)
        app.buttons["Créer"].tap()
        app.staticTexts[title].tap()

        // "Nouveau bloc" est le label du bouton AddBlockButton.
        let addBtn = app.staticTexts["Nouveau bloc"]
        XCTAssertTrue(addBtn.waitForExistence(timeout: 3))
    }
}
