import XCTest

final class TextSelectionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSelectWordCopyAndPasteIntoComposer() {
        verifyCopy(usingKeyboard: false)
    }

    func testExtendSelectionAndCommandCCopy() {
        verifyCopy(usingKeyboard: true)
    }

    private func verifyCopy(usingKeyboard: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-seed-short-chat"]
        app.launch()
        let row = app.staticTexts["Scroll Test"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let body = app.textViews.matching(identifier: "message-text").matching(
            NSPredicate(format: "value CONTAINS %@", "Incoming reply number 5")
        ).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(body.value as? String,
                       "Incoming reply number 5, also long enough to occupy a couple of lines so the thread is tall.")
        body.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 30, dy: 10)).press(forDuration: 1)
        let copy = app.menuItems["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), app.debugDescription)
        if usingKeyboard {
            body.typeKey(.rightArrow, modifierFlags: [.shift, .alternate])
            body.typeKey("c", modifierFlags: .command)
        } else {
            copy.tap()
        }
        let composer = app.textFields["message-field"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.press(forDuration: 1)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), app.debugDescription)
        paste.tap()
        XCTAssertEqual(composer.value as? String, usingKeyboard ? "Incoming reply" : "Incoming")
        XCTAssertFalse(app.buttons["select-text"].exists)
    }
}
