import XCTest

/// Verifies the KeyVault document card end to end on the device: an item is
/// created by typing alone — no Save button exists — and the row persists via
/// autosave; editing an existing item persists the same way.
final class KeyVaultDocumentUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Settings presents a sectioned root; the KeyVault section's link is labeled
/// "Enter" (the section header itself is not a tappable element).
    private func openKeyVault(_ app: XCUIApplication) {
        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10),
                      "Settings button not found")
        settingsButton.tap()

        let link = app.buttons["Enter"].firstMatch
        if link.waitForExistence(timeout: 5) {
            link.tap()
            return
        }
        let label = app.staticTexts["Enter"]
        XCTAssertTrue(label.waitForExistence(timeout: 3), "KeyVault entry not found")
        label.tap()
    }

    func testCreatingAnItemByTypingOnlyPersistsViaAutosave() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        openKeyVault(app)

        let add = app.buttons["add-secure-item"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "Add button missing")
        add.tap()

        // The document card, with no Save button anywhere.
        let title = app.textFields["vault-title-field"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "title field missing")
        XCTAssertFalse(app.buttons["vault-save-button"].exists,
                       "the card must not carry a Save button")
        XCTAssertTrue(app.buttons["vault-done"].exists)

        title.tap()
        title.typeText("Autosave Doc")

        let notes = app.textFields["vault-notes-field"]
        XCTAssertTrue(notes.waitForExistence(timeout: 3), "notes field missing")
        notes.tap()
        notes.typeText("typed without saving")

        // The status pill resolves to Saved once the debounce writes.
        let status = app.staticTexts["vault-save-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5), "status pill missing")
        XCTAssertEqual(status.label, "Saved",
                       "autosave must persist as the reader types (got: \(status.label))")

        // Done closes; the row must already be in the list.
        app.buttons["vault-done"].tap()

        let row = app.staticTexts["Autosave Doc"]
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "the item did not persist via autosave")
    }

    func testEditingAnExistingItemPersistsOnClose() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        openKeyVault(app)

        // Create the item first (typing only).
        let add = app.buttons["add-secure-item"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let title = app.textFields["vault-title-field"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Rename Me")
        XCTAssertTrue(app.staticTexts["vault-save-status"].waitForExistence(timeout: 5))
        app.buttons["vault-done"].tap()
        XCTAssertTrue(app.staticTexts["Rename Me"].waitForExistence(timeout: 5))

        // Reopen it and rename; Done persists.
        app.staticTexts["Rename Me"].tap()
        let field = app.textFields["vault-title-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))

        field.tap()
        // Clear by keyboard (one backspace per character) — deterministic,
        // no dependence on the selection menu's timing.
        field.typeText(String(repeating: "\u{8}", count: "Rename Me".count))
        field.typeText("Renamed Doc")

        XCTAssertTrue(app.staticTexts["vault-save-status"].waitForExistence(timeout: 5))
        app.buttons["vault-done"].tap()

        XCTAssertTrue(app.staticTexts["Renamed Doc"].waitForExistence(timeout: 5),
                      "the rename did not persist")
        XCTAssertFalse(app.staticTexts["Rename Me"].exists,
                       "the old title must be gone from the list")
    }

    func testSecretRoundTripOnTheCard() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-keys"]
        app.launch()

        openKeyVault(app)

        let add = app.buttons["add-secure-item"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()

        let title = app.textFields["vault-title-field"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Keyed Item")

        let secret = app.secureTextFields["vault-secret-field"]
        XCTAssertTrue(secret.waitForExistence(timeout: 3), "secret field missing")
        secret.tap()
        secret.typeText("sk-tinyfish-UITEST004321")

        // The credential card offers the document-style actions.
        XCTAssertTrue(app.buttons["vault-copy-secret"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["vault-generate-secret"].exists)
        XCTAssertTrue(app.buttons["vault-remove-secret"].exists)

        app.buttons["vault-done"].tap()
        XCTAssertTrue(app.staticTexts["Keyed Item"].waitForExistence(timeout: 5),
                      "the item did not persist")

                // The secret was committed on focus loss: reopening shows it masked.
        app.staticTexts["Keyed Item"].tap()
        let masked = app.secureTextFields["vault-secret-field"]
        XCTAssertTrue(masked.waitForExistence(timeout: 5), "secret field missing on reopen")
        XCTAssertEqual(masked.value as? String, String(repeating: "•", count: "sk-tinyfish-UITEST004321".count),
                       "a SecureField renders dots; the count proves the secret survived")

        // Reveal, and the actual value is readable.
        app.buttons["vault-reveal-secret"].tap()
        let revealed = app.textFields["vault-secret-field"]
        XCTAssertTrue(revealed.waitForExistence(timeout: 3), "revealed field missing")
        XCTAssertEqual(revealed.value as? String, "sk-tinyfish-UITEST004321",
                       "the secret did not survive the round trip through the Keychain")
    }
}