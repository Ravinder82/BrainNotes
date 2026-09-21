import XCTest

/// The swipe gesture must still reveal Delete after the scroll fix.
final class SwipeDeleteUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSwipeRevealsDelete() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-store", "-seed-long-chat"]
        app.launch()

        let row = app.staticTexts["Scroll Test"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        let body = app.textViews.matching(identifier: "message-text").matching(
            NSPredicate(format: "value CONTAINS %@", "number 59")
        ).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertTrue(body.isHittable, "Message body is not visible for the swipe")

        // Start in the bubble's top padding, not the UITextView: the row's
        // pan recognizer deliberately declines touches in selectable text.
        let start = body.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0))
            .withOffset(CGVector(dx: 0, dy: -4))
        let end = start.withOffset(CGVector(dx: -160, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: end)

        let delete = app.buttons["Delete message"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3),
                      "Swiping left did not reveal the Delete action")

        let shot = app.screenshot()
        try? shot.pngRepresentation.write(
            to: URL(fileURLWithPath: "/tmp/confabula-swipe-delete.png"))
    }
}