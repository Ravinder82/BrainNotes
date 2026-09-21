import XCTest

/// TEMPORARY probe: walks the KeyVault flow with no assertions that stop it,
/// writing a screenshot after every step so the final layout can be seen.
final class KeyVaultProbeUITests: XCTestCase {
    func testProbeDocumentSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        sleep(2)
        let settingsButton = app.buttons["settings-button"]
        guard settingsButton.waitForExistence(timeout: 10) else { return }
        settingsButton.tap()
        sleep(1)

        let link = app.buttons["Enter"].firstMatch
        if link.exists { link.tap() } else { app.staticTexts["Enter"].tap() }
        sleep(1)

        let add = app.buttons["add-secure-item"]
        guard add.waitForExistence(timeout: 5) else { return }
        add.tap()
        sleep(1)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/kv-final-new.png"))

        let title = app.textFields["vault-title-field"]
        guard title.waitForExistence(timeout: 5) else { return }
        title.tap()
        title.typeText("API Key — OpenAI")
        sleep(1)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/kv-final-typed.png"))

        let secret = app.secureTextFields["vault-secret-field"]
        guard secret.waitForExistence(timeout: 3) else { return }
        secret.tap()
        secret.typeText("sk-tinyfish-DEMO12345678")
        sleep(1)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/kv-final-secret.png"))
    }
}