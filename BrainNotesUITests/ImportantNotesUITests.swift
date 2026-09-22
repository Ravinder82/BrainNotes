import XCTest

/// Verifies the Important Notes page end to end: Settings opens it in one step
/// (no vault list in between), the box only takes text after Edit, and Save
/// keeps the text when the page is opened again.
final class ImportantNotesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Settings lists the page directly, so one tap on the row is the whole
    /// journey — there is no intermediate screen.
    private func openImportantNotes(_ app: XCUIApplication) {
        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10),
                      "Settings button not found")
        settingsButton.tap()

        let link = app.buttons["Important Notes"].firstMatch
        if link.waitForExistence(timeout: 5) {
            link.tap()
            return
        }
        let label = app.staticTexts["Important Notes"]
        XCTAssertTrue(label.waitForExistence(timeout: 3), "Important Notes entry not found")
        label.tap()
    }

    func testSaveKeepsTheTypedText() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        openImportantNotes(app)

        // The page is a text box plus Edit and Save — nothing else.
        let editor = app.textViews["notes-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Notes text box missing")
        XCTAssertTrue(app.buttons["notes-edit-button"].exists, "Edit button missing")
        XCTAssertTrue(app.buttons["notes-save-button"].exists, "Save button missing")

        // Read-only until Edit.
        XCTAssertFalse(editor.isEnabled, "The box should be read-only before Edit")

        app.buttons["notes-edit-button"].tap()
        XCTAssertTrue(editor.isEnabled, "Edit should open the box")

        let text = "Gate code 4815 — renews in March."
        editor.tap()
        editor.typeText(text)

        app.buttons["notes-save-button"].tap()

        // Leave the page and come back: the saved text is still there.
        app.navigationBars.buttons.firstMatch.tap()
        openImportantNotes(app)

        let reopened = app.textViews["notes-editor"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 5), "Notes page did not reopen")
        XCTAssertTrue(reopened.value as? String == text,
                      "Saved notes did not survive reopening (got \(reopened.value ?? "nil"))")
    }

    func testEmptyNotesPageShowsThePlaceholder() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        openImportantNotes(app)

        let editor = app.textViews["notes-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Notes text box missing")
        XCTAssertTrue(app.staticTexts["Write anything worth keeping…"].exists,
                      "Placeholder missing on an empty notes page")

        let shot = app.screenshot()
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/confabula-important-notes.png"))
    }
}
