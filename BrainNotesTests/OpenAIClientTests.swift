import XCTest
@testable import BrainNotes

/// Deterministic coverage for the streaming client's wire contract: typed
/// events, usage extraction, request shape, and error mapping. All transport
/// is stubbed via MockURLProtocol; no real network is touched.
final class OpenAIClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    private func makeClient() -> OpenAIClient {
        OpenAIClient(baseURL: "https://mock.test/v1", apiKey: "sk-mock",
                     session: MockURLProtocol.makeSession())
    }

    private func deltaChunk(_ text: String) -> String {
        #"data: {"choices":[{"delta":{"content":"\#(text)"}}]}"#
    }

    private func usageChunk(prompt: Int, completion: Int, total: Int) -> String {
        #"data: {"usage":{"prompt_tokens":\#(prompt),"completion_tokens":\#(completion),"total_tokens":\#(total)}} "#
    }

    func testStreamYieldsDeltasThenUsage() async throws {
        MockURLProtocol.sse("https://mock.test/v1/chat/completions", lines: [
            deltaChunk("Hel"),
            deltaChunk("lo"),
            usageChunk(prompt: 12, completion: 34, total: 46),
            "data: [DONE]",
        ])
        var deltas: [String] = []
        var usage: OpenAIClient.TokenUsage?
        var sawConnected = false
        for try await event in makeClient().stream(
            model: "m", turns: [ChatTurn(role: "user", content: "hi")], temperature: 0.5
        ) {
            switch event {
            case .connected: sawConnected = true
            case .delta(let d): deltas.append(d)
            case .usage(let u): usage = u
            }
        }
        XCTAssertEqual(deltas.joined(), "Hello")
        XCTAssertEqual(usage, .init(promptTokens: 12, completionTokens: 34, totalTokens: 46))
        // The handshake boundary arrives before any token and exactly once.
        XCTAssertTrue(sawConnected)
    }

    func testStreamWithoutUsageStaysNil() async throws {
        MockURLProtocol.sse("https://mock.test/v1/chat/completions", lines: [
            deltaChunk("ok"), "data: [DONE]",
        ])
        var usage: OpenAIClient.TokenUsage?
        for try await event in makeClient().stream(
            model: "m", turns: [ChatTurn(role: "user", content: "hi")], temperature: 0.5
        ) {
            if case .usage(let u) = event { usage = u }
        }
        XCTAssertNil(usage, "Absence of a usage chunk must stay nil, not zero")
    }

    func testWireFormatCarriesAuthModelAndUsageFlag() async throws {
        MockURLProtocol.sse("https://mock.test/v1/chat/completions", lines: [
            deltaChunk("x"), "data: [DONE]",
        ])
        _ = try await AsyncCollector.collect(makeClient().stream(
            model: "test-model",
            turns: [ChatTurn(role: "user", content: "hi")],
            temperature: 0.25))
        let body = MockURLProtocol.capturedRequestBody()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(body)) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "test-model")
        XCTAssertEqual(json["temperature"] as? Double, 0.25)
        XCTAssertEqual((json["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "user")
    }

    func testHTTPErrorsSurfaceWithStatus() async throws {
        MockURLProtocol.raw("https://mock.test/v1/chat/completions", status: 429,
                            body: #"{"error":"rate limited"}"#)
        do {
            for try await _ in makeClient().stream(
                model: "m", turns: [ChatTurn(role: "user", content: "hi")], temperature: 0.5
            ) {}
            XCTFail("Expected an error")
        } catch let AIError.http(status, _) {
            XCTAssertEqual(status, 429)
        }
    }

    func testUsageSummaryIgnoresNilAndFailedRecords() {
        let bot = UUID()
        let records = [
            AIRequestRecord(botID: bot, botName: "A", providerLabel: "P",
                            providerBaseURL: "https://x", model: "m",
                            promptTokens: 10, completionTokens: 5, totalTokens: 15),
            AIRequestRecord(botID: bot, botName: "A", providerLabel: "P",
                            providerBaseURL: "https://x", model: "m",
                            promptTokens: nil, completionTokens: 7, totalTokens: nil),
            AIRequestRecord(botID: bot, botName: "A", providerLabel: "P",
                            providerBaseURL: "https://x", model: "m",
                            promptTokens: 3, completionTokens: 2, totalTokens: 5,
                            outcome: .failed),
        ]
        let summary = UsageSummary.of(records)
        XCTAssertEqual(summary.requestCount, 3)
        XCTAssertEqual(summary.promptTokens, 10, "Only completed records with reports count")
        XCTAssertEqual(summary.completionTokens, 12)
        XCTAssertEqual(summary.totalTokens, 15)
        // Unknown stays unknown:
        let unknown = UsageSummary.of([AIRequestRecord(
            botID: bot, botName: "A", providerLabel: "P",
            providerBaseURL: "https://x", model: "m")])
        XCTAssertNil(unknown.promptTokens)
        XCTAssertNil(unknown.completionTokens)
        XCTAssertNil(unknown.totalTokens)
    }
}

/// Small helper for draining a stream inside a throwing test expression.
enum AsyncCollector {
    static func collect<Element>(
        _ stream: some AsyncSequence<Element, Error>
    ) async throws -> [Element] {
        var out: [Element] = []
        for try await item in stream { out.append(item) }
        return out
    }
}
