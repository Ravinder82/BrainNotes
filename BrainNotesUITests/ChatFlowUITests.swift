import XCTest

final class ChatFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Creates a bot from the empty state and asserts it appears in the list.
    func testCreateBotAppearsInList() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-store"]
        app.launch()

        // Empty state offers "Create a bot"; toolbar "+" always works.
        let create = app.buttons["New bot"]
        XCTAssertTrue(create.waitForExistence(timeout: 5),
                      "New bot button not found")
        create.tap()

        // Editor should appear with a name field.
        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5),
                      "Bot editor did not open")
        nameField.tap()
        nameField.typeText("Ada")

        // Save.
        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 3), "Save button missing")
        save.tap()

        // The new bot row should show up in the chat list.
        XCTAssertTrue(app.staticTexts["Ada"].waitForExistence(timeout: 5),
                      "Created bot did not appear in the chat list")

        let shot = app.screenshot()
        try? shot.pngRepresentation.write(
            to: URL(fileURLWithPath: "/tmp/confabula-bot-created.png"))
    }

    /// Opens a bot's chat and asserts the composer responds to typing.
    func testOpenChatAndType() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-store"]
        app.launch()

        let create = app.buttons["New bot"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()

        let nameField = app.textFields.firstMatch
        // The editor is a sheet; under full-suite load its presentation can
        // outlive a short timeout even though nothing is wrong.
        XCTAssertTrue(nameField.waitForExistence(timeout: 12))
        nameField.tap()
        nameField.typeText("Grace")
        app.buttons["Save"].tap()

        let row = app.staticTexts["Grace"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        // Chat composer: type a message.
        let composer = app.textFields["message-field"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5),
                      "Composer not found in chat view")
        composer.tap()
        composer.typeText("Hello there")

        let shot = app.screenshot()
        try? shot.pngRepresentation.write(
            to: URL(fileURLWithPath: "/tmp/confabula-chat-typed.png"))

        XCTAssertEqual(composer.value as? String, "Hello there",
                       "Typed text did not appear in the composer")
    }
}
