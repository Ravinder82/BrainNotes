import XCTest

/// Verifies the unified provider screen: one place to set endpoint, model and
/// API key, with the key persisting to the Keychain.
final class SettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Opens the first provider's unified detail screen.
    ///
    /// Settings presents a sectioned root first, so the provider list is one
    /// push deeper than it used to be.
    private func openProviderDetail(_ app: XCUIApplication) {
        let providersLink = app.buttons["AI Providers"].firstMatch
        if providersLink.waitForExistence(timeout: 5) {
            providersLink.tap()
        } else if app.staticTexts["AI Providers"].waitForExistence(timeout: 3) {
            app.staticTexts["AI Providers"].tap()
        }

        let row = app.buttons["provider-card"].firstMatch
        if row.waitForExistence(timeout: 5) {
            row.tap()
            return
        }
        // Fall back to the visible provider name.
        let named = app.staticTexts["OpenAI"]
        XCTAssertTrue(named.waitForExistence(timeout: 5),
                      "No provider card found")
        named.tap()
    }

    func testStoreOpenFailureDoesNotExposeTemporaryChats() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-simulate-store-open-failure"]
        app.launch()

        let title = app.staticTexts["Unable to Open Saved Data"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings-button"].exists)
        let retry = app.buttons["storage-retry"]
        XCTAssertTrue(retry.exists)
        retry.tap()
        XCTAssertTrue(title.exists)
        XCTAssertFalse(app.buttons["settings-button"].exists)
    }

    func testProviderScreenIsUnified() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-keys"]
        app.launch()

        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5),
                      "Settings button not found")
        settingsButton.tap()

        openProviderDetail(app)

        // Endpoint, model and key must all live on this one screen.
        XCTAssertTrue(app.textFields["provider-baseurl"].waitForExistence(timeout: 5),
                      "Base URL field missing from provider screen")
        XCTAssertTrue(app.textFields["provider-model"].exists,
                      "Model field missing from provider screen")
        XCTAssertTrue(app.secureTextFields["api-key-field"].exists
                      || app.textFields["api-key-field"].exists,
                      "API key field missing from provider screen")

        let shot = app.screenshot()
        try? shot.pngRepresentation.write(
            to: URL(fileURLWithPath: "/tmp/confabula-provider-unified.png"))
    }

    func testSaveApiKeyPersistsToKeychain() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-keys"]
        app.launch()

        app.buttons["settings-button"].tap()
        openProviderDetail(app)

        let field = app.secureTextFields["api-key-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5),
                      "API key field not found")
        field.tap()
        field.typeText("sk-test-1234567890")

        app.buttons["provider-save"].tap()

        // A keychain failure keeps the screen open with an error banner.
        let error = app.staticTexts["keychain-error"]
        if error.waitForExistence(timeout: 3) {
            XCTFail("Keychain save failed: \(error.label)")
        }

        let shot = app.screenshot()
        try? shot.pngRepresentation.write(
            to: URL(fileURLWithPath: "/tmp/confabula-provider-saved.png"))

        // Reopen: the stored key must be readable again. A SecureField reports
        // its value as bullets, so compare length rather than the plaintext.
        openProviderDetail(app)
        let reopened = app.secureTextFields["api-key-field"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 5),
                      "Provider screen did not reopen")
        let masked = reopened.value as? String ?? ""
        XCTAssertEqual(masked.count, "sk-test-1234567890".count,
                       "Stored key did not survive the round trip (got \(masked.count) chars)")
    }

    /// Gemini must be offered in the quick-fill provider list.
    func testGeminiPresetAvailable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-keys"]
        app.launch()

        app.buttons["settings-button"].tap()
        openProviderDetail(app)

        // Wait for the detail screen to settle before tapping, otherwise the
        // tap can land during the presentation animation and do nothing.
        let quickFill = app.buttons["Quick fill from a known provider"]
        XCTAssertTrue(quickFill.waitForExistence(timeout: 10),
                      "Provider detail screen did not appear")
        quickFill.tap()

        // The presets sheet needs its own wait; it is presented from inside
        // the detail sheet and animates in.
        XCTAssertTrue(app.navigationBars["Providers"].waitForExistence(timeout: 10),
                      "Preset picker sheet did not open")

        let gemini = app.staticTexts["Google Gemini"]
        XCTAssertTrue(gemini.waitForExistence(timeout: 5),
                      "Gemini missing from the provider quick list")
    }
}