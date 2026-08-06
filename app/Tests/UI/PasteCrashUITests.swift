import XCTest
import UIKit

// A tester reported the app quitting when pasting content copied from
// ChatGPT into a leaf. "Quitting" — not an error alert — points at a
// crash rather than a handled failure.
//
// Two details matter for reproducing it faithfully:
//
//  - Copying from ChatGPT puts HTML and RTF on the pasteboard, not just
//    plain text. `simctl pbcopy` only sets plain text, which is why a
//    first attempt at this test paste nothing interesting. The rich
//    flavours are what UITextView turns into an attributed string with
//    foreign fonts, attachments and link attributes.
//
//  - "New block" opens the block picker; the editor is only focused
//    after choosing a type. Pasting before that sends the keystroke to
//    the sheet and tests nothing.

final class PasteCrashUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// UI tests share the simulator's pasteboard with the app, so the
    /// rich flavours can be staged from here.
    private func stageRichClipboard() {
        let html = """
        <h2>Ontologie h\u{00E9}bra\u{00EF}que</h2>
        <p>Voici un <b>r\u{00E9}sum\u{00E9}</b> <i>structur\u{00E9}</i> :</p>
        <ol><li>Le terme <em>dabar</em> (\u{05D3}\u{05B8}\u{05D1}\u{05B8}\u{05E8}) signifie « parole ».</li>
        <li>La racine <code>\u{05DB}\u{05EA}\u{05D1}</code> \u{2014} cf.
        <a href="https://www.sefaria.org/Genesis.1.1">Gen\u{00E8}se 1:1</a>.</li></ol>
        <blockquote>Au commencement, Dieu cr\u{00E9}a les cieux et la terre.</blockquote>
        <pre>{ "racine": "\u{05DB}\u{05EA}\u{05D1}", "occurrences": 223 }</pre>
        <table><tr><td>dabar</td><td>parole</td></tr></table>
        <p>Attention aux nuances \u{1F642} \u{2014} « voil\u{00E0} »\u{2026}</p>
        """
        let plain = "Ontologie hébraïque — dabar (דָּבָר) 🙂 « voilà »…"
        var item: [String: Any] = ["public.utf8-plain-text": plain]
        if let data = html.data(using: .utf8) { item["public.html"] = data }
        if let rtf = try? NSAttributedString(
            data: Data(html.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html],
            documentAttributes: nil
        ).data(from: NSRange(location: 0, length: 1),
               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            item["public.rtf"] = rtf
        }
        UIPasteboard.general.items = [item]
    }

    /// ChatGPT answers routinely contain diagrams, and copying a region
    /// that includes one puts image data on the pasteboard alongside the
    /// text. UITextView then inserts an NSTextAttachment, which is a
    /// shape the span conversion never sees when typing.
    private func stageClipboardWithImage() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 600))
        let image = renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
        }
        var item: [String: Any] = [
            "public.utf8-plain-text": "Schéma — ontologie hébraïque 🙂",
            "public.png": image.pngData() as Any,
        ]
        item["public.html"] = Data("<p>Voir le <b>schéma</b> :</p><img src=\"x.png\">".utf8)
        UIPasteboard.general.items = [item]
    }

    func testPastingContentWithAnImageDoesNotCrash() {
        stageClipboardWithImage()
        let app = focusedEditor()

        let pasteButton = app.buttons["Paste"]
        XCTAssertTrue(pasteButton.waitForExistence(timeout: 5))
        pasteButton.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        Thread.sleep(forTimeInterval: 4)

        let state = app.state
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "apres-collage-image"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertEqual(state, .runningForeground,
                       "app state after pasting an image: \(state.rawValue)")
    }

    /// Opens a seeded leaf and focuses a real text block, going through
    /// the picker the way a user does.
    private func focusedEditor() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-data"]
        app.launch()

        let row = app.staticTexts.byLabel("Seeded Leaf 1")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        let newBlock = app.staticTexts.byLabel("New block")
        XCTAssertTrue(newBlock.waitForExistence(timeout: 10))
        newBlock.tap()

        // The picker must be dismissed by choosing a type, otherwise the
        // keystroke lands on the sheet.
        let textOption = app.staticTexts["Text"]
        XCTAssertTrue(textOption.waitForExistence(timeout: 5), "block picker never appeared")
        textOption.tap()
        XCTAssertFalse(app.staticTexts["Add a block"].waitForExistence(timeout: 2),
                       "block picker stayed up — the paste would go to the sheet")
        return app
    }

    func testPastingRichContentDoesNotCrash() {
        stageRichClipboard()
        let app = focusedEditor()

        // The editor's own toolbar button, not Cmd-V: the simulator has
        // no hardware keyboard attached, so typeKey silently pastes
        // nothing and the test proves nothing. This button calls
        // `paste(nil)` on the text view — the real UIKit paste path.
        let pasteButton = app.buttons["Paste"]
        XCTAssertTrue(pasteButton.waitForExistence(timeout: 5),
                      "the toolbar Paste button is not reachable")
        pasteButton.tap()

        // iOS asks permission when the pasteboard was filled by another
        // process — here, the test runner. The prompt belongs to
        // SpringBoard, so it cannot be reached through `app`. Without
        // this, the paste never happens and the test proves nothing.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        Thread.sleep(forTimeInterval: 4)

        // `state` is the only honest liveness probe: a missing element
        // could just mean the view scrolled or a sheet covered it. A
        // dead app reports .notRunning.
        let state = app.state
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "apres-collage-riche"; shot.lifetime = .keepAlways; add(shot)

        XCTAssertEqual(state, .runningForeground,
                       "app state after paste: \(state.rawValue) — 4 is running, 1 is dead")
    }
}
