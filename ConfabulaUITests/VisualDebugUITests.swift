import XCTest

/// TEMPORARY diagnostic harness: opens seeded threads and writes raw
/// screenshots into /tmp so the rendering can be inspected outside the test.
final class VisualDebugUITests: XCTestCase {

    private func launch(seed: String, appearance: XCUIDevice.Appearance) -> XCUIApplication {
        XCUIDevice.shared.appearance = appearance
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", seed]
        app.launch()
        return app
    }

    private func openChat(_ app: XCUIApplication, name: String) {
        let row = app.staticTexts[name]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Seeded row missing")
        row.tap()
        sleep(2)
    }

    private func write(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        try? shot.pngRepresentation.write(
            to: URL(fileURLWithPath: "/tmp/vd-\(name).png"))
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSnapshotRichLight() throws {
        let app = launch(seed: "-seed-rich-chat", appearance: .light)
        openChat(app, name: "Rich Test")
        write(app, "light-rich-bottom")

        app.scrollViews.firstMatch.swipeDown()
        sleep(1)
        write(app, "light-rich-mid")

        for _ in 0..<3 { app.scrollViews.firstMatch.swipeDown() }
        sleep(1)
        write(app, "light-rich-top")
    }

    func testSnapshotRichDark() throws {
        let app = launch(seed: "-seed-rich-chat", appearance: .dark)
        openChat(app, name: "Rich Test")
        write(app, "dark-rich-bottom")

        for _ in 0..<3 { app.scrollViews.firstMatch.swipeDown() }
        sleep(1)
        write(app, "dark-rich-top")
    }

    func testSnapshotLongThread() throws {
        let app = launch(seed: "-seed-long-chat", appearance: .light)
        openChat(app, name: "Scroll Test")
        write(app, "light-long-thread")
    }

    func testProbeLayout() throws {
        let app = launch(seed: "-probe-layout", appearance: .light)
        sleep(2)
        write(app, "probe-layout")
    }

    func testDumpRichHierarchy() throws {
        let app = launch(seed: "-seed-rich-chat", appearance: .light)
        openChat(app, name: "Rich Test")
        print("HIERARCHY-START")
        print(app.debugDescription)
        print("HIERARCHY-END")
    }

    func testSnapshotComposerAndMenu() throws {
        let app = launch(seed: "-seed-long-chat", appearance: .light)
        openChat(app, name: "Scroll Test")

        let composer = app.textFields["message-field"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Checking the composer layout")
        sleep(1)
        write(app, "light-composer-typed")
        // The keyboard reduces the viewport; reveal the newest message before
        // querying its lazily created text and menu controls.
        let thread = app.scrollViews["chat-thread"]
        XCTAssertTrue(thread.waitForExistence(timeout: 5))
        thread.swipeUp()

        // Open the explicit actions menu. Long press on the message body now
        // belongs to native text selection, not message actions.
        let body = app.textViews.matching(identifier: "message-text").matching(
            NSPredicate(format: "value CONTAINS %@", "number 59")
        ).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        let actions = app.buttons.matching(identifier: "message-actions").matching(
            NSPredicate(format: "value CONTAINS %@", "number 59")
        ).firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        XCTAssertEqual(actions.label, "Message actions")
        actions.tap()

        let copy = app.buttons["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 3),
                      "Message actions button did not present the actions menu")
        write(app, "light-actions-menu")
        let reply = app.buttons["Reply"]
        XCTAssertTrue(reply.waitForExistence(timeout: 3),
                      "Message actions menu did not present Reply")
        reply.tap()
        sleep(1)
        write(app, "light-reply-preview")
    }
}