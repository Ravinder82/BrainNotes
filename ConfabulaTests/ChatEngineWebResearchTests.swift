import XCTest
import SwiftData
@testable import Confabula

/// The engine's research round, end to end inside the process: a stubbed model
/// asks for a web search, the stubbed web answers, and the persisted reply is
/// the grounded answer — with no fence anywhere in it.
///
/// This is the piece unit-tested seams cannot prove on their own: that the
/// block a bot emits is intercepted, executed, fed back, and stripped, and
/// that exactly one clean reply lands in the thread.
@MainActor
final class ChatEngineWebResearchTests: XCTestCase {
    /// Held for the test's lifetime: `mainContext` does not keep its container
    /// alive on its own, and a deallocated container traps on the next fetch.
    private var container: ModelContainer?

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Harness

    private func makeContext() throws -> ModelContext {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let schema = Schema([Bot.self, Message.self, SecureItem.self, Crew.self])
        let config = ModelConfiguration(schema: schema, url: directory)
        let made = try ModelContainer(for: schema, configurations: [config])
        container = made
        return made.mainContext
    }

    /// A provider pointed at the stubbed endpoint, active for the engine.
    private func makeProviders() -> (ProviderStore, ProviderConfig) {
        let providers = ProviderStore()
        let provider = ProviderConfig(id: UUID(), label: "Test", baseURL: "https://llm.test/v1",
                                      defaultModel: "test-model", isActive: false)
        providers.upsert(provider)
        providers.setActive(provider.id)
        providers.setAPIKey("sk-test", for: provider.id)
        return (providers, provider)
    }

    /// First model call returns `blockReply`, every later one returns `answer` —
    /// the shape of a researched turn.
    private func stubModel(blockReply: String, answer: String) {
        let calls = CallCounter()
        MockURLProtocol.stub("https://llm.test/v1/chat/completions") { request in
            let text = calls.next() == 1 ? blockReply : answer
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/event-stream"])!
            // One line per chunk, exactly as the streaming client's own tests
            // deliver them.
            let chunks = [Data((sseDeltaLine(text) + "\n").utf8),
                          Data("data: [DONE]\n".utf8)]
            return MockURLProtocol.Stub(response: response, body: .streamed(chunks, intervalMs: 0))
        }
    }

    private func makeEngine(_ providers: ProviderStore) -> ChatEngine {
        let webTools = WebToolStore(defaults: UserDefaults(suiteName: "webtools.engine.\(UUID().uuidString)")!,
                                    keys: InMemoryWebKeyStore())
        webTools.session = MockURLProtocol.makeSession()
        let engine = ChatEngine(providers: providers, webTools: webTools)
        engine.session = MockURLProtocol.makeSession()
        return engine
    }

    /// `send` starts the stream and returns, so tests wait for it to settle.
    private func waitForStream(_ engine: ChatEngine) async throws {
        let deadline = Date().addingTimeInterval(10)
        while engine.isStreaming && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(engine.isStreaming, "stream did not finish in time")
    }

    // MARK: - Tests

    func testBlockIsResearchedThenStrippedFromThePersistedReply() async throws {
        let context = try makeContext()
        let bot = Bot(name: "Trend Scout", role: "Researcher")
        context.insert(bot)

        MockURLProtocol.raw("https://api.search.tinyfish.ai", status: 200, body: """
        {"query":"ramen","results":[{"position":1,"site_name":"ny.eater.com","title":"Where to Get Ramen",
         "snippet":"Spicy tonkotsu…","url":"https://ny.eater.com/ramen"}],"total_results":1,"page":0}
        """)

        let block = """
        I'll check the live page.

        ```confabula-web
        {"ops":[{"op":"search","query":"ramen"}]}
        ```
        """
        let answer = "The best ramen list is [Eater](https://ny.eater.com/ramen)."
        stubModel(blockReply: block, answer: answer)

        let (providers, provider) = makeProviders()
        defer { providers.remove(provider.id) }
        let engine = makeEngine(providers)

        await engine.send("where should I eat", to: bot, in: context)
        try await waitForStream(engine)

        let reply = try XCTUnwrap(bot.sortedMessages.last)
        XCTAssertFalse(reply.isFromMe, "the last message should be the bot's reply")
        XCTAssertEqual(reply.delivery, .delivered)
        XCTAssertFalse(reply.text.contains("confabula-web"),
                       "machine syntax must never persist: \(reply.text)")
        XCTAssertEqual(reply.text, "I'll check the live page.\n\n" + answer)

        // Exactly one reply landed — no second bubble for the research round.
        let botMessages = bot.sortedMessages.filter { !$0.isFromMe }
        XCTAssertEqual(botMessages.count, 1)

        // The second model call carried the search results in its last turn.
        let chatBodies = (0..<4).compactMap { MockURLProtocol.capturedRequestBody(at: $0) }
            .compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .filter { $0["messages"] != nil }
        XCTAssertEqual(chatBodies.count, 2, "expected a first round and a research round")
        let messages = try XCTUnwrap(chatBodies.last?["messages"] as? [[String: Any]])
        let injected = messages.last?["content"] as? String ?? ""
        XCTAssertTrue(injected.contains("[confabula-web-results]"), "results must be fed back")
        XCTAssertTrue(injected.contains("https://ny.eater.com/ramen"),
                      "the model needs the source URL")
    }

    func testBlockWithToolsOffLeavesOnlyProse() async throws {
        let context = try makeContext()
        let bot = Bot(name: "Lone Specialist")
        context.insert(bot)

        let block = """
        I would look that up.

        ```confabula-web
        {"ops":[{"op":"search","query":"anything"}]}
        ```
        """
        stubModel(blockReply: block, answer: "unused")

        let (providers, provider) = makeProviders()
        defer { providers.remove(provider.id) }

        // The owner has switched both providers off: no key is on file.
        let store = WebToolStore(defaults: UserDefaults(suiteName: "webtools.off.\(UUID().uuidString)")!,
                                 keys: InMemoryWebKeyStore())
        store.removeKey(for: .tinyfish)
        store.removeKey(for: .monid)
        XCTAssertFalse(store.anyActive)

        let engine = ChatEngine(providers: providers, webTools: store)
        engine.session = MockURLProtocol.makeSession()

        await engine.send("hello", to: bot, in: context)
        try await waitForStream(engine)

        let reply = try XCTUnwrap(bot.sortedMessages.last)
        XCTAssertEqual(reply.text, "I would look that up.",
                       "with no tools, the fence is stripped and the prose stands alone")
        XCTAssertEqual(reply.delivery, .delivered)
    }
}

/// One SSE delta line carrying `text`, JSON-escaped by Foundation so a block's
/// newlines survive as data instead of breaking the payload.
///
/// File scope, not a method: the stub closure is `@Sendable`, so it cannot call
/// a main-actor-isolated helper.
private func sseDeltaLine(_ text: String) -> String {
    let object: [String: Any] = ["choices": [["delta": ["content": text]]]]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return "data: " + String(decoding: data, as: UTF8.self)
}

/// Thread-safe call counter for stubs that must answer differently per request.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}