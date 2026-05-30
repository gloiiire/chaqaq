import XCTest

// Tests E2E (XCUITest) : pilote l'app comme un utilisateur réel.
// XCUITest reste sur XCTest classique (Swift Testing ne couvre pas la UI).

final class HomeScreenUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunchesAndShowsGreeting() {
        let app = XCUIApplication()
        app.launch()
        // L'une des trois salutations selon l'heure doit apparaître.
        let greetings = ["Bonjour.", "Bon après-midi.", "Bonsoir."]
        let predicate = NSPredicate(format: "label IN %@", greetings)
        let header = app.staticTexts.element(matching: predicate)
        XCTAssertTrue(header.waitForExistence(timeout: 5))
    }

    func testFloatingButtonOpensCreateSheet() {
        let app = XCUIApplication()
        app.launch()
        // Le FAB d'accueil utilise l'icône "square.and.pencil" — son accessibilityLabel
        // par défaut suffit à le retrouver, ou on cible le bouton avec icône.
        let fab = app.buttons["createDocumentFAB"]
        XCTAssertTrue(fab.waitForExistence(timeout: 3))
        fab.tap()
        // La sheet de création doit afficher "Nouveau document".
        XCTAssertTrue(app.staticTexts["Nouveau document"].waitForExistence(timeout: 3))
    }
}

private extension XCUIElementQuery {
    var lastMatch: XCUIElement { element(boundBy: count - 1) }
}
