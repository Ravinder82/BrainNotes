import XCTest

/// Guards against the swipe-to-delete gesture regressing vertical scrolling in
/// the chat thread.
final class ChatScrollUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testChatThreadScrolls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-store", "-seed-long-chat"]
        app.launch()

        // Open the seeded conversation.
        let row = app.staticTexts["Scroll Test"]
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "Seeded chat row not found")
        row.tap()

        // The newest message is visible first (thread anchors to the bottom).
        let newest = app.textViews.matching(identifier: "message-text").matching(
            NSPredicate(format: "value CONTAINS %@", "number 59")
        ).firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 5),
                      "Newest message not visible on open")

        // Scroll up: older content must come into view. If the row-level drag
        // gesture is swallowing drags, this never appears.
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5),
                      "Scroll view not found")

        var foundOlder = false
        for _ in 0..<8 {
            scroll.swipeDown()
            let older = app.textViews.matching(identifier: "message-text").matching(
                NSPredicate(format: "value CONTAINS %@", "number 10 ")
            ).firstMatch
            if older.exists {
                foundOlder = true
                break
            }
        }
        XCTAssertTrue(foundOlder,
                      "Chat did not scroll: older messages never became visible")

        let shot = app.screenshot()
        try? shot.pngRepresentation.write(
            to: URL(fileURLWithPath: "/tmp/confabula-scrolled.png"))
    }
}