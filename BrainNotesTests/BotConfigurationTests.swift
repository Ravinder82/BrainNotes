import XCTest
import SwiftData
@testable import BrainNotes

@MainActor
final class BotConfigurationTests: XCTestCase {
    func testAgeBoundaries() {
        for age in [12, 17] { XCTAssertEqual(AgePerspective.resolve(age), .pulse) }
        for age in [18, 25] { XCTAssertEqual(AgePerspective.resolve(age), .builder) }
        for age in [26, 39] { XCTAssertEqual(AgePerspective.resolve(age), .operatorMindset) }
        for age in [40, 50] { XCTAssertEqual(AgePerspective.resolve(age), .auditor) }
    }

    func testCompilerPreservesExamplesAndMapsTemperatureDirectly() {
        let bot = Bot(name: "Audit", role: "Financial Auditor", negativeRules: "Never invent metrics.",
                      systemPersonality: "Inspect the evidence first.",
                      goldenExamples: "Input: Revenue?\nOutput: **Unverified**\n\n  Keep indentation.",
                      agePerspective: 45, creativity: 0.35)
        let compiled = compileBotSystemPrompt(bot: bot)
        XCTAssertEqual(compiled.temperature, 0.35)
        XCTAssertEqual(compiled.systemPrompt, """
        <agent_identity>
        Role: Financial Auditor
        COGNITIVE PERSPECTIVE (Age ~45): Desires evidentiary proof, risk mitigation, and compliance. Highly skeptical auditor mindset. Zero tolerance for unverified claims or hype; cross-examines assumptions.
        </agent_identity>

        <strict_negative_constraints>
        CRITICAL: You are strictly penalized for violating any of the following negative boundaries:
        Never invent metrics.
        </strict_negative_constraints>

        <personality_and_workflow>
        Inspect the evidence first.
        </personality_and_workflow>

        <golden_output_exemplars>
        CRITICAL INSTRUCTION: The following examples represent the target standard of output quality, analytical density, formatting, and depth. Match this caliber precisely:
        Input: Revenue?
        Output: **Unverified**

          Keep indentation.
        </golden_output_exemplars>
        """)
        for value in [0.0, 0.05, 0.5, 1.0] {
            bot.creativity = value
            XCTAssertEqual(compileBotSystemPrompt(bot: bot).temperature, value)
        }
    }

    func testLegacyMigrationIsIdempotent() {
        let bot = Bot(name: "Legacy")
        bot.configurationVersion = 0
        bot.persona = "Preserve my instructions.\n  Exactly."
        bot.temperature = 1.8
        bot.migrateConfigurationIfNeeded()
        XCTAssertEqual(bot.systemPersonality, bot.persona)
        XCTAssertEqual(bot.creativity, 1)
        XCTAssertEqual(bot.agePerspective, 33)
        XCTAssertEqual(bot.configurationVersion, 1)
        bot.systemPersonality = ""
        bot.creativity = 0.2
        bot.migrateConfigurationIfNeeded()
        XCTAssertEqual(bot.systemPersonality, "")
        XCTAssertEqual(bot.creativity, 0.2)
    }

    func testConfigurationSurvivesStoreReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bots.store")
        let schema = Schema([Bot.self, Message.self, SecureItem.self])
        let config = ModelConfiguration(schema: schema, url: url)
        var botID: UUID!
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            let bot = Bot(name: "Saved", role: "Auditor", negativeRules: "No hype",
                          systemPersonality: "Check facts", goldenExamples: "Input -> Output\n  Detail",
                          agePerspective: 50, creativity: 0.05)
            botID = bot.id
            container.mainContext.insert(bot)
            try container.mainContext.save()
        }
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            let bot = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<Bot>()).first)
            XCTAssertEqual(bot.id, botID)
            XCTAssertEqual(bot.role, "Auditor")
            XCTAssertEqual(bot.negativeRules, "No hype")
            XCTAssertEqual(bot.systemPersonality, "Check facts")
            XCTAssertEqual(bot.goldenExamples, "Input -> Output\n  Detail")
            XCTAssertEqual(bot.agePerspective, 50)
            XCTAssertEqual(bot.creativity, 0.05)
            bot.migrateConfigurationIfNeeded()
            XCTAssertEqual(bot.systemPersonality, "Check facts")
        }
    }
}
