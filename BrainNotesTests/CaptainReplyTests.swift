import XCTest
@testable import BrainNotes

/// Covers the display-side split of a Captain reply: prose for the bubble,
/// the action block lifted out for the crew card. The block must leave no
/// raw JSON in what the reader sees, in success and failure alike.
final class CaptainReplyTests: XCTestCase {

    func testPlainReplyParsesToNil() {
        XCTAssertNil(CaptainReply.parse("Just a chat reply, no actions here."))
    }

    func testReplyWithActionsStripsFenceAndDecodes() {
        let reply = """
        Here's my proposed team.

        ```confabula-actions
        [
          {
            "action": "create_specialist",
            "name": "AI Trend Scout",
            "role": "Extract the top trending AI topics each week.",
            "responsibilities": ["Rank the five biggest stories"],
            "negativeRules": "Never invent sources.",
            "agePerspective": 33,
            "creativity": 0.5
          }
        ]
        ```

        Approve and I'll draft first assignments.
        """

        let parsed = CaptainReply.parse(reply)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.actions.count, 1)
        XCTAssertNil(parsed?.failure)
        XCTAssertTrue(parsed?.hasCard == true)

        let prose = parsed?.prose ?? ""
        XCTAssertTrue(prose.contains("Here's my proposed team."))
        XCTAssertTrue(prose.contains("Approve and I'll draft first assignments."))
        // The machine payload is never part of what the reader sees.
        XCTAssertFalse(prose.contains("confabula-actions"))
        XCTAssertFalse(prose.contains("\"create_specialist\""))
        XCTAssertFalse(prose.contains("```"))

        guard case .createSpecialist(let spec)? = parsed?.actions.first
        else { return XCTFail("Expected a create_specialist action") }
        XCTAssertEqual(spec.name, "AI Trend Scout")
    }

    func testBlockOnlyReplyLeavesEmptyProse() {
        let reply = """
        ```confabula-actions
        [{"action":"create_specialist","name":"Scout","role":"Watches trends."}]
        ```
        """
        let parsed = CaptainReply.parse(reply)
        XCTAssertEqual(parsed?.prose, "")
        XCTAssertEqual(parsed?.actions.count, 1)
        XCTAssertTrue(parsed?.hasCard == true)
    }

    func testInvalidJSONKeepsProseAndReportsFailure() {
        let reply = """
        Team proposal:

        ```confabula-actions
        [ { "action": "create_specialist", "name": }
        ```
        """
        let parsed = CaptainReply.parse(reply)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.prose, "Team proposal:")
        XCTAssertNil(parsed?.actions.first)
        XCTAssertNotNil(parsed?.failure)
        // The card still renders — to explain the failure.
        XCTAssertTrue(parsed?.hasCard == true)
        XCTAssertFalse(parsed?.prose.contains("```") ?? true)
    }

    func testUnclosedFenceLeavesMessageUntouched() {
        // A reply cut off mid-block renders as plain text rather than
        // swallowing everything after the marker.
        let reply = "Partial reply\n```confabula-actions\n[{\"action\":"
        XCTAssertNil(CaptainReply.parse(reply))
    }

    func testUnknownActionSurfacesFailure() {
        let reply = """
        ```confabula-actions
        [{"action":"delete_everything"}]
        ```
        """
        let parsed = CaptainReply.parse(reply)
        XCTAssertEqual(parsed?.actions.count, 0)
        XCTAssertNotNil(parsed?.failure)
    }

    // MARK: - Regression: "Captain is not generating any output"

    /// The bug behind a bubble that read only "Understood.": every fence-less
    /// Captain reply was cut to its first sentence, hiding the interview
    /// question, answer, or critique that followed it.
    func testReplyWithoutActionsShowsFullProse() {
        let reply = "Understood. Which platform should ship first — iOS or web?"
        XCTAssertEqual(CaptainReply.statusLine(forReply: reply), reply)
    }

    /// A model prepending a language tag used to defeat BOTH the engine (no
    /// crew created, silently) and this parser (no card). Both now agree.
    func testLanguageTaggedFenceStillParses() {
        let reply = """
        On it.

        ```json-confabula-actions
        [{"action":"create_specialist","name":"Scout","role":"Watches trends."}]
        ```
        """
        let parsed = CaptainReply.parse(reply)
        XCTAssertEqual(parsed?.actions.count, 1)
        XCTAssertEqual(parsed?.prose, "On it.")
        XCTAssertNotNil(CaptainAction.envelope(in: reply),
                        "Engine-side extraction must match display-side parsing")
        XCTAssertEqual(CaptainReply.statusLine(forReply: reply),
                       "Added a specialist to the roster.")
    }

    /// A fence carrying nothing to act on must not hide the reply behind a
    /// canned status either.
    func testEmptyActionBlockFallsBackToProse() {
        let reply = """
        Nothing to change yet — here is the plan.

        ```confabula-actions
        []
        ```
        """
        XCTAssertEqual(CaptainReply.statusLine(forReply: reply),
                       "Nothing to change yet — here is the plan.")
    }

    /// A block the stream cut off mid-fence is stripped from display, not
    /// shown as machine syntax — while `parse` still declines it (see
    /// testUnclosedFenceLeavesMessageUntouched).
    func testStripRemovesUnclosedActionBlock() {
        let partial = "Partial reply\n```confabula-actions\n[{\"action\":"
        XCTAssertNil(CaptainReply.parse(partial))
        XCTAssertEqual(CaptainAction.stripBlocks(partial), "Partial reply")
        XCTAssertEqual(CaptainReply.statusLine(forReply: partial), "Partial reply")
    }

    /// Status lines still derive from validated actions only — the card's
    /// detail keeps its one-line summary.
    func testActionBlockStillCollapsesToStatusLine() {
        let reply = """
        Here is the team.

        ```confabula-actions
        [{"action":"create_specialist","name":"Scout","role":"Watches trends."}]
        ```
        """
        XCTAssertEqual(CaptainReply.statusLine(forReply: reply),
                       "Added a specialist to the roster.")
    }
}
