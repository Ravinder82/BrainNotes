import XCTest

/// Verifies the Web Search & Data screen: both providers render, a key saves to
/// the Keychain and renders masked, and the switch drives the active summary.
final class WebToolsSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Settings presents a sectioned root, so the web screen is one push deeper.
    private func openWebTools(_ app: XCUIApplication) {
        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5),
                      "Settings button not found")
        settingsButton.tap()

        let link = app.buttons["Web Search & Data"].firstMatch
        if link.waitForExistence(timeout: 5) {
            link.tap()
            return
        }
        let label = app.staticTexts["Web Search & Data"]
        XCTAssertTrue(label.waitForExistence(timeout: 3), "Web Search & Data entry not found")
        label.tap()
    }

    /// SwiftUI renders a `Toggle` as a switch in some configurations and a
    /// button in others; find whichever element the runtime actually produced.
    private func toggle(_ app: XCUIApplication, provider: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "webtools-toggle-\(provider)")
            .firstMatch
    }

    func testBothProvidersRenderWithTheirControls() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-keys"]
        app.launch()

        openWebTools(app)

        for provider in ["tinyfish", "monid"] {
            XCTAssertTrue(toggle(app, provider: provider).waitForExistence(timeout: 5),
                          "\(provider) switch missing")
            XCTAssertTrue(app.buttons["webtools-test-\(provider)"].waitForExistence(timeout: 5),
                          "\(provider) probe button missing")
        }

        // A reset leaves both cards key-less: the fields are shown, not masks.
        XCTAssertTrue(app.secureTextFields["webtools-key-field-tinyfish"].exists)
        XCTAssertTrue(app.secureTextFields["webtools-key-field-monid"].exists)
        XCTAssertFalse(app.staticTexts["webtools-masked-tinyfish"].exists,
                       "a reset must not leave a key behind")
        XCTAssertEqual(app.staticTexts["webtools-active-summary"].label, "No tools active")
    }

    func testSavingAKeyMasksItAndActivatesTheProvider() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-keys"]
        app.launch()

        openWebTools(app)

        let field = app.secureTextFields["webtools-key-field-tinyfish"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "key field missing")
        field.tap()
        field.typeText("sk-tinyfish-UITEST00001234")

        app.buttons["webtools-save-tinyfish"].tap()

        let masked = app.staticTexts["webtools-masked-tinyfish"]
        XCTAssertTrue(masked.waitForExistence(timeout: 5), "saved key was not shown masked")
        XCTAssertEqual(masked.label, "sk-tinyfish-…1234")
        XCTAssertEqual(app.staticTexts["webtools-active-summary"].label, "TinyFish active")

        // Replacing and removing are offered once a key is on file.
        XCTAssertTrue(app.buttons["webtools-replace-tinyfish"].exists)
        XCTAssertTrue(app.buttons["webtools-remove-tinyfish"].exists)

        toggle(app, provider: "tinyfish").tap()
        XCTAssertEqual(app.staticTexts["webtools-active-summary"].label, "No tools active",
                       "switching a provider off must clear it from the summary")
    }

    func testSwitchingOffKeepsTheSavedKey() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-keys"]
        app.launch()

        openWebTools(app)

        let field = app.secureTextFields["webtools-key-field-monid"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("monid_live_UITEST00004321")
        app.buttons["webtools-save-monid"].tap()

        XCTAssertTrue(app.staticTexts["webtools-masked-monid"].waitForExistence(timeout: 5))

        toggle(app, provider: "monid").tap()
        XCTAssertEqual(app.staticTexts["webtools-active-summary"].label, "No tools active")
        XCTAssertTrue(app.staticTexts["webtools-masked-monid"].exists,
                      "switching off must not discard the key")
    }
}