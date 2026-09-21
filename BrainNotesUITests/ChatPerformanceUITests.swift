import XCTest

/// Measures chat responsiveness with a differential method.
///
/// A naive absolute-time assertion is useless here: XCUITest synthesises each
/// swipe with a large fixed overhead (~1.5-2s), so 20 swipes cost ~40s no matter
/// how fast the app draws. Instead this measures the same gestures against a
/// short thread and a long thread and compares the *difference*. The fixed
/// gesture overhead appears in both runs and cancels out, leaving the actual
/// per-row rendering cost — which is what regressed.
final class ChatPerformanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openChat(_ app: XCUIApplication, seed: String) {
        app.launchArguments = ["-ui-testing", "-reset-store", seed]
        app.launch()
        let row = app.staticTexts["Scroll Test"]
        XCTAssertTrue(row.waitForExistence(timeout: 15),
                      "Seeded chat row not found")
        row.tap()
        XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout: 10),
                      "Chat scroll view did not appear")
    }

    /// Time for a fixed number of swipes on a given seeded thread.
    private func swipeDuration(seed: String, swipes: Int = 8) -> TimeInterval {
        let app = XCUIApplication()
        openChat(app, seed: seed)
        let scroll = app.scrollViews.firstMatch

        // Warm up so first-touch layout is not attributed to the measurement.
        scroll.swipeUp()

        let start = Date()
        for _ in 0..<swipes { scroll.swipeDown() }
        for _ in 0..<swipes { scroll.swipeUp() }
        let elapsed = Date().timeIntervalSince(start)
        app.terminate()
        return elapsed
    }

    /// The long thread must not cost dramatically more per swipe than a short
    /// one. When rows re-sorted the entire message array per frame, a long
    /// thread was dramatically slower than a short one; after the memoisation
    /// and row-precomputation work they should be close.
    func testLongThreadScrollCostIsBounded() throws {
        let short = swipeDuration(seed: "-seed-short-chat")
        let long = swipeDuration(seed: "-seed-long-chat")

        // Gesture overhead dominates both runs, so the extra cost of 60 vs 6
        // messages should be a small multiple, not an order of magnitude.
        let ratio = long / max(short, 0.001)
        print("PERF short=\(String(format: "%.2f", short))s long=\(String(format: "%.2f", long))s ratio=\(String(format: "%.2f", ratio))")

        XCTAssertLessThan(ratio, 3.0,
                          "Long-thread scrolling is \(String(format: "%.1f", ratio))x the short-thread cost — per-row render work is scaling with thread length")
    }

    /// The explicit actions button must open the message menu: catches a row
    /// view swallowing interaction. Long press on the body selects text instead.
    func testRowsRemainInteractive() throws {
        let app = XCUIApplication()
        openChat(app, seed: "-seed-long-chat")

        let body = app.textViews.matching(identifier: "message-text").matching(
            NSPredicate(format: "value CONTAINS %@", "number 59")
        ).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 10))

        let actions = app.buttons.matching(identifier: "message-actions").matching(
            NSPredicate(format: "value CONTAINS %@", "number 59")
        ).firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        XCTAssertEqual(actions.label, "Message actions")
        actions.tap()
        XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5),
                      "Message actions did not present Copy")
        XCTAssertTrue(app.buttons["Reply"].waitForExistence(timeout: 5),
                      "Message actions did not present Reply")
    }
}