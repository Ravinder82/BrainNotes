import XCTest

/// Guards Captain's mission surface: the crew deck above the thread, the
/// manifest card in place of raw action JSON, crew-to-detail navigation, and
/// tap-anywhere keyboard dismissal.
///
/// Captain's unit of work is now the crew, not the lone specialist. The deck
/// shows crew cards; the manifest inside the thread lists each crew's members;
/// tapping a crew card opens the crew detail where a member can be opened
/// directly.
final class CrewDeckUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-store", "-seed-captain-crew"]
        app.launch()
    }

    private func openCaptain() {
        let card = app.buttons["captain-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10),
                      "Captain card missing from the chat list")
        card.tap()
    }

    /// Every crew card on the deck. Each card is a `NavigationLink` (a button)
    /// so the query is type-scoped for stable re-resolution.
    private func crewDeckCards() -> XCUIElementQuery {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "crew-deck-card-"))
    }

    /// The Content Squad card specifically. The deck sorts crews by activity,
    /// so the "first" card is not guaranteed to be any one crew; targeting by
    /// label lets the navigation steps follow a known member deterministically.
    private func contentSquadCard() -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                        "crew-deck-card-", "Content Squad")).firstMatch
    }

    func testDeckManifestAndNavigation() throws {
        openCaptain()

        // The deck shows crews (cards), not individual specialists. Two seeded
        // crews ride the deck. The rail can take a beat to populate after the
        // push, so poll for both cards rather than asserting a stale snapshot.
        let deckCards = crewDeckCards()
        let cardsReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count == 2"), object: deckCards)
        XCTAssertEqual(XCTWaiter().wait(for: [cardsReady], timeout: 8), .completed,
                       "Expected two seeded crews on the deck")

        // The manifest reply renders as a card, and the raw action block is
        // nowhere in the visible text.
        let card = app.descendants(matching: .any)["crew-manifest-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 5),
                      "Crew manifest card missing from the thread")
        let leaked = app.textViews.matching(identifier: "message-text")
            .matching(NSPredicate(format: "value CONTAINS %@", "confabula-actions"))
        XCTAssertEqual(leaked.count, 0,
                       "Raw action fence leaked into the visible thread")

        // The manifest lists every seeded specialist on its own row.
        for name in ["Trend Scout", "Script Chef", "Fact Sentinel",
                     "Source Finder", "Verifier"] {
            let found = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == %@",
                                      "crew-member-\(name)")).firstMatch
            XCTAssertTrue(
                found.waitForExistence(timeout: 3),
                "\(name) missing from the manifest card")
        }

        // Deck card opens the crew's own group chat — the surface where the
        // work actually happens. Target the Content Squad card so the step is
        // deterministic. Re-resolve the card fresh on each attempt — a cached
        // firstMatch can go stale once the accessibility tree regenerates.
        var openedChat = false
        for _ in 0..<3 where !openedChat {
            let squadCard = contentSquadCard()
            if squadCard.waitForExistence(timeout: 2) {
                squadCard.tap()
            }
            openedChat = app.otherElements["crew-chat-title"]
                .waitForExistence(timeout: 3)
            if !openedChat {
                openedChat = app.textFields["crew-message-field"]
                    .waitForExistence(timeout: 3)
            }
        }
        XCTAssertTrue(openedChat,
                      "Tapping a deck card did not open the crew group chat")

        // The crew chat is a working surface: it has its own composer.
        XCTAssertTrue(app.textFields["crew-message-field"].waitForExistence(timeout: 5),
                      "Crew group chat is missing its composer")
        XCTAssertTrue(app.buttons["crew-send-button"].exists,
                      "Crew group chat is missing its send button")

        // The roster is still reachable from the crew chat, and each member
        // can still be opened for a private 1:1.
        app.buttons["Crew chat options"].tap()
        app.buttons["Crew details"].tap()

        let memberRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Trend Scout")).firstMatch
        XCTAssertTrue(memberRow.waitForExistence(timeout: 5),
                      "Crew details did not list the seeded members")
        let header = app.buttons["Trend Scout, online"]
        var openedMemberChat = false
        for _ in 0..<3 where !openedMemberChat {
            memberRow.tap()
            openedMemberChat = header.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(openedMemberChat,
                      "Tapping a crew member did not open their private chat")
    }

    func testTapOutsideComposerDismissesKeyboard() throws {
        openCaptain()

        let field = app.textFields["message-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Status report")

        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 5) else {
            throw XCTSkip("Software keyboard did not appear in the simulator")
        }

        // Tap the thread background above the bubbles: the seeded thread is
        // short, so the top of the thread is empty wallpaper-side space.
        let thread = app.scrollViews["chat-thread"]
        XCTAssertTrue(thread.exists, "Chat thread not found")
        thread.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()

        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 3),
                      "Tapping the thread background did not dismiss the keyboard")
    }
}
