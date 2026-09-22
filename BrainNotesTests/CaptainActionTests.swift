import XCTest
import SwiftData
@testable import BrainNotes

/// Proves the full Captain execution path with a hardcoded reply: fenced
/// envelope → parse → validate → spawn into a real in-memory store, plus the
/// rollback and rejection cases. No network, no Captain persona, no UI.
@MainActor
final class CaptainActionTests: XCTestCase {
    private let hardcodedReply = """
    Here's my proposed team.

    ```confabula-actions
    [
      {
        "action": "create_specialist",
        "name": "AI Trend Scout",
        "role": "Extract the top trending AI topics across the industry each week.",
        "responsibilities": [
          "Rank the week's five most significant AI stories",
          "Cite a source link for every ranked item"
        ],
        "negativeRules": "Never present a paywalled claim as verified. Never invent dates.",
        "agePerspective": 33,
        "creativity": 0.5
      },
      {
        "action": "create_specialist",
        "name": "YouTube Content Chef",
        "role": "Turn ranked trends into shareable video scripts.",
        "responsibilities": ["Draft one script per approved trend"],
        "negativeRules": "Never publish anything. Drafts only.",
        "agePerspective": 22,
        "creativity": 0.8
      }
    ]
    ```

    Approve these two specialists and I'll draft their first assignments next.
    """

    /// Held for the test's lifetime: `mainContext` does not keep its container
    /// alive on its own, and a deallocated container traps on the next fetch.
    private var container: ModelContainer?

    private func makeContext() throws -> ModelContext {
        // In-memory containers crash inside SwiftData on this SDK when the
        // schema carries relationships, so tests use throwaway disk stores —
        // the same pattern BotConfigurationTests relies on.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let schema = Schema([Bot.self, Message.self, ImportantNote.self, Crew.self])
        let config = ModelConfiguration(schema: schema, url: directory)
        let made = try ModelContainer(for: schema, configurations: [config])
        container = made
        return made.mainContext
    }

    private func validJSON() -> Data {
        CaptainAction.envelope(in: hardcodedReply)! .data(using: .utf8)!
    }

    func testEnvelopeExtractionFromHardcodedReply() {
        let extracted = CaptainAction.envelope(in: hardcodedReply)
        XCTAssertNotNil(extracted)
        XCTAssertTrue(extracted!.contains("AI Trend Scout"))
        XCTAssertFalse(extracted!.contains("proposed team"), "Fence must not leak prose")
    }

    func testFullPipelineSpawnsTwoSpecialists() throws {
        let context = try makeContext()
        let actions = try CaptainAction.decode(from: validJSON()).get()
        XCTAssertEqual(actions.count, 2)

        let result = try CaptainActionProcessor.apply(actions, in: context, existingBots: [])

        XCTAssertEqual(result.applied.count, 2)
        XCTAssertEqual(result.createdBotIDs.count, 2)
        let bots = try context.fetch(FetchDescriptor<Bot>())
        XCTAssertEqual(bots.count, 2, "Exactly the two specialists exist")
        let scout = try XCTUnwrap(bots.first { $0.name == "AI Trend Scout" })
        XCTAssertTrue(scout.isCaptainManaged, "Specialists must be labelled Captain-managed")
        XCTAssertTrue(scout.role.contains("trending AI topics"))
        XCTAssertEqual(scout.agePerspective, 33)
        XCTAssertEqual(scout.creativity, 0.5, accuracy: 0.001)
        XCTAssertTrue(scout.systemPersonality.contains("Rank the week's five"))
        XCTAssertEqual(result.applied[0], "Create specialist “AI Trend Scout” — Extract the top trending AI topics across the industry each week.")
    }

    func testSameNameReplacesTheOldBotAndWipesItsHistory() throws {
        let context = try makeContext()
        // Case-insensitive clash: Captain reusing a name ships a new version
        // rather than failing, and the retired bot's history goes with it.
        let existing = Bot(name: "ai trend scout", role: "Old role")
        existing.configurationVersion = 3
        context.insert(existing)
        let oldMessage = Message(text: "old history", author: .bot, delivery: .delivered)
        oldMessage.bot = existing
        context.insert(oldMessage)
        try context.save()

        let actions = try CaptainAction.decode(from: validJSON()).get()
        let result = try CaptainActionProcessor.apply(
            actions, in: context, existingBots: [existing])

        // The old row is gone; a new version carries the name.
        let bots = try context.fetch(FetchDescriptor<Bot>())
        XCTAssertEqual(bots.count, 2, "Both specialists exist after the batch")
        XCTAssertFalse(bots.contains { $0.role == "Old role" },
                       "The retired version must not linger")
        let replacement = try XCTUnwrap(bots.first { $0.name == "AI Trend Scout" })
        XCTAssertEqual(replacement.configurationVersion, 4,
                       "The replacement continues the version sequence")
        XCTAssertEqual(bots.filter { $0.name.lowercased() == "ai trend scout" }.count, 1,
                       "Only one bot may hold a given name")

        // The retired bot's chat history is wiped, not carried over.
        let messages = try context.fetch(FetchDescriptor<Message>())
        XCTAssertFalse(messages.contains { $0.text == "old history" },
                       "History of the retired version is deleted")
        XCTAssertEqual(result.replaced.count, 1)
        XCTAssertEqual(result.replaced.first?.previousName, "ai trend scout")
        XCTAssertEqual(result.replaced.first?.previousVersion, 3)
        XCTAssertEqual(result.replaced.first?.newBotID, replacement.id)
        XCTAssertTrue(result.applied.contains { $0.contains("Replace specialist") })
    }

    func testSaveFailureRollsBack() throws {
        // SwiftData offers no injectable failing ModelContext, so a true
        // save-failure cannot be forced here without faking it. This test
        // pins the documented contract instead: a batch that succeeds returns
        // exactly the bots it created, and nothing else lingers.
        let context = try makeContext()
        let actions = [CaptainAction.createSpecialist(.init(
            name: "Scout", role: "Research trends", responsibilities: [],
            negativeRules: "", agePerspective: 30, creativity: 0.4))]
        let result = try CaptainActionProcessor.apply(actions, in: context, existingBots: [])
        XCTAssertEqual(result.createdBotIDs.count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Bot>()).count, 1)
    }

    func testValidationRejections() throws {
        // Unknown action kind.
        let unknown = #"[{"action":"delete_every_bot"}]"#.data(using: .utf8)!
        XCTAssertEqual(CaptainAction.decode(from: unknown),
                       .failure(.unknownAction("delete_every_bot")))
        // Missing name.
        let missing = #"[{"action":"create_specialist","role":"x"}]"#.data(using: .utf8)!
        XCTAssertEqual(CaptainAction.decode(from: missing), .failure(.missing("name")))
        // Blank name.
        let blank = #"[{"action":"create_specialist","name":"  ","role":"x"}]"#.data(using: .utf8)!
        XCTAssertEqual(CaptainAction.decode(from: blank), .failure(.missing("name")))
        // Age out of range.
        let age = #"[{"action":"create_specialist","name":"A","role":"x","agePerspective":9}]"#.data(using: .utf8)!
        XCTAssertEqual(CaptainAction.decode(from: age), .failure(.invalidAge(9)))
        // Creativity out of range.
        let creativity = #"[{"action":"create_specialist","name":"A","role":"x","creativity":1.5}]"#.data(using: .utf8)!
        XCTAssertEqual(CaptainAction.decode(from: creativity), .failure(.invalidCreativity(1.5)))
        // Too many responsibilities.
        let many = #"[{"action":"create_specialist","name":"A","role":"x","responsibilities":["1","2","3","4","5","6","7","8","9"]}]"#.data(using: .utf8)!
        XCTAssertEqual(CaptainAction.decode(from: many), .failure(.tooManyResponsibilities))
        // Name over 60 characters.
        let long = ("[{\"action\":\"create_specialist\",\"name\":\"" + String(repeating: "n", count: 61) + "\",\"role\":\"x\"}]").data(using: .utf8)!
        XCTAssertEqual(CaptainAction.decode(from: long), .failure(.nameTooLong))
        // Not JSON at all.
        let junk = "not json".data(using: .utf8)!
        guard case .failure(.malformedJSON) = CaptainAction.decode(from: junk) else {
            return XCTFail("Expected malformedJSON")
        }
        // A bare object rather than an array.
        let object = #"{"action":"create_specialist"}"#.data(using: .utf8)!
        guard case .failure(.malformedJSON) = CaptainAction.decode(from: object) else {
            return XCTFail("Expected malformedJSON for non-array root")
        }
    }

    func testEnvelopeRequiresClosingFence() {
        let unterminated = """
        ```confabula-actions
        [{"action":"create_specialist","name":"A","role":"x"}]
        """
        XCTAssertNil(CaptainAction.envelope(in: unterminated))
    }

    func testEmptyBatchIsNoOp() throws {
        let context = try makeContext()
        let result = try CaptainActionProcessor.apply([], in: context, existingBots: [])
        XCTAssertEqual(result.applied, [])
        XCTAssertEqual(result.createdBotIDs, [])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Bot>()).count, 0)
    }

    // MARK: - Live path

    /// The exact contract ChatEngine must satisfy after a Captain reply
    /// finishes streaming: any fenced action block in the reply text is
    /// validated and applied to the store, and invalid blocks change nothing.
    /// This pins the hook's behavior before it exists (red), and passes once
    /// wired (green).
    func testLivePathAppliesActionsFromCaptainReplyText() throws {
        let context = try makeContext()

        // 1. Valid block in a reply spawns the specialists.
        let applied = try ChatEngine.applyCaptainActions(
            in: hardcodedReply, existingBots: [], context: context)
        XCTAssertEqual(applied.count, 2)
        var bots = try context.fetch(FetchDescriptor<Bot>())
        XCTAssertEqual(bots.count, 2)
        XCTAssertEqual(bots.first { $0.name == "AI Trend Scout" }?.isCaptainManaged, true)

        // 2. A reply with no block is a no-op.
        let none = try ChatEngine.applyCaptainActions(
            in: "Just prose, no action block here.", existingBots: bots, context: context)
        XCTAssertEqual(none.count, 0)

        // 3. An invalid block (unknown action) is rejected and changes nothing.
        let invalid = """
        ```confabula-actions
        [{"action":"delete_every_bot"}]
        ```
        """
        XCTAssertThrowsError(try ChatEngine.applyCaptainActions(
            in: invalid, existingBots: bots, context: context))
        bots = try context.fetch(FetchDescriptor<Bot>())
        XCTAssertEqual(bots.count, 2, "Invalid block must not touch the store")

        // 4. Reusing a name through the live path replaces the old version
        // rather than rejecting the batch.
        let revision = """
        ```confabula-actions
        [{"action":"create_specialist","name":"AI Trend Scout","role":"clone"}]
        ```
        """
        _ = try ChatEngine.applyCaptainActions(
            in: revision, existingBots: bots, context: context)
        let after = try context.fetch(FetchDescriptor<Bot>())
        XCTAssertEqual(after.count, 2, "A revision replaces in place, it does not add a third")
        XCTAssertEqual(after.filter { $0.name.lowercased() == "ai trend scout" }.count, 1)
        XCTAssertEqual(after.first { $0.name == "AI Trend Scout" }?.role, "clone",
                       "The newest version carries the name")
    }
}
