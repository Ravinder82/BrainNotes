import XCTest
@testable import Confabula

/// Covers the web-tools feature end to end at the seams that matter: the two
/// wire clients, the block protocol the bots speak, the store's key and switch
/// behaviour, and the research pass's prompt shaping.
final class WebToolsTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - TinyFish

    func testSearchMapsHitsAndDropsRowsWithoutURL() async throws {
        MockURLProtocol.raw("https://api.search.tinyfish.ai", status: 200, body: """
        {"query":"x","results":[
          {"position":1,"site_name":"ny.eater.com","title":"Where to Get Ramen","snippet":"Spicy tonkotsu…","url":"https://ny.eater.com/ramen","date":"2 days ago"},
          {"position":2,"title":"No URL here","snippet":"…"}
        ],"total_results":2,"page":0}
        """)

        let client = TinyFishClient(apiKey: "k", session: MockURLProtocol.makeSession())
        let hits = try await client.search(query: "x")

        XCTAssertEqual(hits.count, 1, "rows without a URL cannot be cited or fetched")
        XCTAssertEqual(hits[0].url, "https://ny.eater.com/ramen")
        XCTAssertEqual(hits[0].siteName, "ny.eater.com")
        XCTAssertEqual(hits[0].date, "2 days ago")
        XCTAssertEqual(hits[0].position, 1)
    }

    func testSearchThrowsHelpfulErrorOnAuthFailure() async throws {
        MockURLProtocol.raw("https://api.search.tinyfish.ai", status: 401, body: #"{"message":"bad key"}"#)

        let client = TinyFishClient(apiKey: "nope", session: MockURLProtocol.makeSession())
        do {
            _ = try await client.search(query: "x")
            XCTFail("expected an auth failure")
        } catch let error as WebToolError {
            XCTAssertTrue(error.localizedDescription.contains("authentication"),
                          "got: \(error.localizedDescription)")
        }
    }

    func testFetchReturnsPagesAndPerURLFailures() async throws {
        MockURLProtocol.raw("https://api.fetch.tinyfish.ai", status: 200, body: """
        {"results":[{"url":"https://a.com","final_url":"https://a.com/","title":"A","description":"D",
                     "language":"en","text":"# Hello"}],
         "errors":[{"url":"https://b.com","error":"timed out"}]}
        """)

        let client = TinyFishClient(apiKey: "k", session: MockURLProtocol.makeSession())
        let result = try await client.fetch(urls: ["https://a.com", "https://b.com"])

        XCTAssertEqual(result.pages.count, 1)
        XCTAssertEqual(result.pages[0].text, "# Hello")
        XCTAssertEqual(result.pages[0].finalURL, "https://a.com/")
        XCTAssertEqual(result.failures.count, 1, "a dead URL must not sink the other pages")
        XCTAssertEqual(result.failures[0].error, "timed out")
    }

    // MARK: - Monid

    func testDiscoverMapsCandidatesWithPrices() async throws {
        MockURLProtocol.raw("https://api.monid.ai/v1/discover", status: 200, body: """
        {"results":[{"provider":"octen","providerName":"Octen","endpoint":"/extract",
                     "description":"Extract clean markdown","score":0.72,
                     "price":{"type":"PER_RESULT","amount":{"value":0.001,"currency":"USD"}},
                     "tags":["verified"],"metrics":{}}],
         "query":"extract","count":1}
        """)

        let client = MonidClient(apiKey: "k", session: MockURLProtocol.makeSession())
        let endpoints = try await client.discover(query: "extract")

        XCTAssertEqual(endpoints.count, 1)
        XCTAssertEqual(endpoints[0].provider, "octen")
        XCTAssertEqual(endpoints[0].endpoint, "/extract")
        XCTAssertEqual(endpoints[0].displayName, "Octen · /extract")
        XCTAssertEqual(endpoints[0].priceLine, "$0.001 per result",
                       "a bot must see the price before it spends")
    }

    func testRunSyncCompletionReturnsOutput() async throws {
        MockURLProtocol.raw("https://api.monid.ai/v1/run", status: 200, body: """
        {"runId":"01H","provider":"pdl","endpoint":"/person/enrich","status":"COMPLETED",
         "output":{"full_name":"John Doe"},
         "providerResponse":{"httpStatus":200},"billedUnits":1}
        """)

        let client = MonidClient(apiKey: "k", session: MockURLProtocol.makeSession())
        let result = try await client.run(provider: "pdl", endpoint: "/person/enrich", input: [:])

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.providerHTTPStatus, 200)
        XCTAssertEqual(result.billedUnits, 1)
        XCTAssertTrue(result.outputJSON.contains("John Doe"))
    }

    func testRunWithProvider404IsAResultNotATransportFailure() async throws {
        // Sync runs mirror the provider's HTTP status; the body is still a
        // perfectly good run envelope describing "no match", which costs
        // nothing and is exactly what the bot should be told.
        MockURLProtocol.raw("https://api.monid.ai/v1/run", status: 404, body: """
        {"runId":"01H","provider":"pdl","endpoint":"/person/enrich","status":"COMPLETED","output":null,
         "providerResponse":{"httpStatus":404,"error":{"status":404,"message":"No match found for the given query"}},
         "billedUnits":0}
        """)

        let client = MonidClient(apiKey: "k", session: MockURLProtocol.makeSession())
        let result = try await client.run(provider: "pdl", endpoint: "/person/enrich", input: [:])

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.providerHTTPStatus, 404)
        XCTAssertEqual(result.providerErrorMessage, "No match found for the given query")
        XCTAssertTrue(result.summaryLine.contains("No match found"))
    }

    func testRunAsyncPollsUntilTerminal() async throws {
        // Registered generic-first: MockURLProtocol picks the last matching
        // prefix, so the more specific poll URL must be registered after the
        // run URL it also matches.
        MockURLProtocol.raw("https://api.monid.ai/v1/run", status: 202, body: """
        {"runId":"01HXYZ","provider":"apify","endpoint":"/tweet-scraper","status":"READY"}
        """)
        MockURLProtocol.raw("https://api.monid.ai/v1/runs/", status: 200, body: """
        {"runId":"01HXYZ","status":"COMPLETED","output":{"items":["a","b"]},
         "providerResponse":{"httpStatus":200},"billedUnits":2}
        """)

        let client = MonidClient(apiKey: "k", session: MockURLProtocol.makeSession())
        let result = try await client.run(provider: "apify", endpoint: "/tweet-scraper",
                                          input: ["searchTerms": .array([.string("AI")])],
                                          pollInterval: 0.05, timeout: 5)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.runID, "01HXYZ")
        XCTAssertEqual(result.billedUnits, 2)
        XCTAssertTrue(result.outputJSON.contains("\"a\""))
    }

    // MARK: - Block protocol

    func testParseLiftsOpsOutOfTheFenceAndLeavesProse() throws {
        let reply = """
        Let me check that live.

        ```confabula-web
        {"ops":[{"op":"search","query":"berlin ai act","domain":"news"},
                {"op":"fetch","urls":["https://a.com"]}]}
        ```
        """

        let call = try XCTUnwrap(WebToolRequest.parse(reply))
        XCTAssertEqual(call.prose, "Let me check that live.")
        XCTAssertEqual(call.ops.count, 2)
        XCTAssertTrue(call.failures.isEmpty)

        guard case .search(let query, _, let domain, _) = call.ops[0] else {
            return XCTFail("first op should be a search")
        }
        XCTAssertEqual(query, "berlin ai act")
        XCTAssertEqual(domain, "news")

        guard case .fetch(let urls, _) = call.ops[1] else {
            return XCTFail("second op should be a fetch")
        }
        XCTAssertEqual(urls, ["https://a.com"])

        // The persisted text never carries the fence, block or not.
        XCTAssertEqual(WebToolRequest.stripBlocks(reply), "Let me check that live.")
    }

    func testParseReturnsNilWhenThereIsNoBlock() {
        XCTAssertNil(WebToolRequest.parse("Just an ordinary answer."))
        XCTAssertEqual(WebToolRequest.stripBlocks("Just an ordinary answer."),
                       "Just an ordinary answer.")
    }

    func testMalformedOpsBecomeNotesForTheModel() throws {
        let reply = """
        ```confabula-web
        {"ops":[{"op":"google","query":"x"},{"op":"search"}]}
        ```
        """

        let call = try XCTUnwrap(WebToolRequest.parse(reply))
        XCTAssertTrue(call.ops.isEmpty)
        XCTAssertEqual(call.failures.count, 2)
        XCTAssertTrue(call.failures[0].contains("Unknown operation"))
        XCTAssertTrue(call.failures[1].contains("`query`"))
        XCTAssertEqual(call.prose, "")
    }

    func testBlockIsCappedAtThreeOperations() throws {
        let reply = """
        ```confabula-web
        {"ops":[{"op":"search","query":"a"},{"op":"search","query":"b"},
                {"op":"search","query":"c"},{"op":"search","query":"d"}]}
        ```
        """

        let call = try XCTUnwrap(WebToolRequest.parse(reply))
        XCTAssertEqual(call.ops.count, WebToolRequest.maxOps)
        XCTAssertTrue(call.failures.contains { $0.contains("first 3") })
    }

    func testRunOpCarriesStructuredInput() throws {
        let reply = """
        ```confabula-web
        {"op":"run","provider":"apify","endpoint":"/tweet-scraper",
         "input":{"searchTerms":["AI"],"maxItems":10}}
        ```
        """

        let call = try XCTUnwrap(WebToolRequest.parse(reply))
        guard case .run(let provider, let endpoint, let input) = call.ops[0] else {
            return XCTFail("expected a run op")
        }
        XCTAssertEqual(provider, "apify")
        XCTAssertEqual(endpoint, "/tweet-scraper")
        XCTAssertEqual(input["maxItems"], .number(10))
        XCTAssertEqual(input["searchTerms"], .array([.string("AI")]))
    }

    // MARK: - Prompt section

    func testPromptSectionNamesOnlyTheEnabledProviders() throws {
        let tinyfishOnly = try XCTUnwrap(WebAccessPrompt.section(tinyfish: true, monid: false))
        XCTAssertTrue(tinyfishOnly.contains("`search`"))
        XCTAssertTrue(tinyfishOnly.contains("`fetch`"))
        XCTAssertFalse(tinyfishOnly.contains("inspect"))
        XCTAssertFalse(tinyfishOnly.contains("`run`"))

        let monidOnly = try XCTUnwrap(WebAccessPrompt.section(tinyfish: false, monid: true))
        XCTAssertTrue(monidOnly.contains("`data`"))
        XCTAssertTrue(monidOnly.contains("`run`"))
        XCTAssertFalse(monidOnly.contains("`fetch`"))

        XCTAssertNil(WebAccessPrompt.section(tinyfish: false, monid: false),
                     "a bot is never told about tools it does not have")
    }

    // MARK: - Store

    @MainActor
    func testStoreSeedsTheGivenKeysOnce() {
        let defaults = makeDefaults()
        let keys = InMemoryWebKeyStore()

        let store = WebToolStore(defaults: defaults, keys: keys)
        XCTAssertTrue(store.hasKey(for: .tinyfish))
        XCTAssertTrue(store.hasKey(for: .monid))
        XCTAssertEqual(store.key(for: .monid), WebToolDefaults.monidKey)
        XCTAssertTrue(store.anyActive, "both providers ship switched on")
        XCTAssertTrue(store.isActive(.tinyfish))

        // Removing a key is durable: a later launch must not re-seed it.
        store.removeKey(for: .tinyfish)
        let relaunched = WebToolStore(defaults: defaults, keys: keys)
        XCTAssertFalse(relaunched.hasKey(for: .tinyfish))
        XCTAssertTrue(relaunched.hasKey(for: .monid))
    }

    @MainActor
    func testMaskedKeyShowsTheTailOnly() {
        let store = WebToolStore(defaults: makeDefaults(), keys: InMemoryWebKeyStore())
        store.setKey("sk-tinyfish-ABCDEFGH1234", for: .tinyfish)

        let masked = store.maskedKey(for: .tinyfish)
        XCTAssertEqual(masked, "sk-tinyfish-…1234")
        XCTAssertFalse(masked?.contains("ABCDEFGH") ?? true,
                       "the middle of a key must never render")
    }

    @MainActor
    func testSwitchPersistsButKeyRemains() {
        let defaults = makeDefaults()
        let keys = InMemoryWebKeyStore()
        let store = WebToolStore(defaults: defaults, keys: keys)

        store.setEnabled(false, for: .monid)
        XCTAssertFalse(store.isEnabled(.monid))
        XCTAssertTrue(store.hasKey(for: .monid), "switching off keeps the saved key")
        XCTAssertFalse(store.isActive(.monid))
        XCTAssertTrue(store.isActive(.tinyfish))

        let relaunched = WebToolStore(defaults: defaults, keys: keys)
        XCTAssertFalse(relaunched.isEnabled(.monid), "the switch is remembered")
    }

    @MainActor
    func testProbeWithoutAKeyFailsSoftly() async {
        let store = WebToolStore(defaults: makeDefaults(), keys: InMemoryWebKeyStore())
        store.removeKey(for: .tinyfish)

        await store.probe(.tinyfish)

        XCTAssertEqual(store.probes[.tinyfish], .failed("No key saved yet."))
    }

    @MainActor
    func testProbeReportsSuccessWithLatency() async {
        MockURLProtocol.raw("https://api.search.tinyfish.ai", status: 200, body: """
        {"query":"q","results":[{"position":1,"title":"T","url":"https://a.com","snippet":"S"}],"total_results":1,"page":0}
        """)
        let store = WebToolStore(defaults: makeDefaults(), keys: InMemoryWebKeyStore())
        store.session = MockURLProtocol.makeSession()

        await store.probe(.tinyfish)

        guard case .passed(let message)? = store.probes[.tinyfish] else {
            return XCTFail("expected a pass, got \(String(describing: store.probes[.tinyfish]))")
        }
        XCTAssertTrue(message.contains("Connected"), "got: \(message)")
        XCTAssertTrue(message.contains("1 results"), "got: \(message)")
    }

    @MainActor
    func testProbeSurfacesAMonidBalance() async {
        MockURLProtocol.raw("https://api.monid.ai/v1/wallet/balance", status: 200, body: """
        {"balance":{"value":1,"currency":"USD"},"held":{"value":0,"currency":"USD"}}
        """)
        let store = WebToolStore(defaults: makeDefaults(), keys: InMemoryWebKeyStore())
        store.session = MockURLProtocol.makeSession()

        await store.probe(.monid)

        XCTAssertEqual(store.monidBalance?.value, 1)
        guard case .passed(let message)? = store.probes[.monid] else {
            return XCTFail("expected a pass")
        }
        XCTAssertTrue(message.contains("balance"), "got: \(message)")
    }

    // MARK: - Research pass

    @MainActor
    func testResearchFlagsUnavailableToolsInsteadOfFailing() async {
        let store = WebToolStore(defaults: makeDefaults(), keys: InMemoryWebKeyStore())
        store.removeKey(for: .tinyfish)
        store.removeKey(for: .monid)
        XCTAssertFalse(store.anyActive)

        let outcome = await WebResearch(store: store).run(.init(
            prose: "",
            ops: [.search(query: "anything", purpose: nil, domain: nil, recencyMinutes: nil)],
            failures: []))

        XCTAssertFalse(outcome.producedData)
        XCTAssertTrue(outcome.modelText.contains("TOOL UNAVAILABLE"),
                      "got: \(outcome.modelText)")
        XCTAssertTrue(outcome.modelText.contains("TinyFish"))
    }

    @MainActor
    func testResearchFormatsSearchResultsForTheModel() async {
        MockURLProtocol.raw("https://api.search.tinyfish.ai", status: 200, body: """
        {"query":"ramen","results":[
          {"position":1,"site_name":"ny.eater.com","title":"Where to Get Ramen","snippet":"Spicy tonkotsu…","url":"https://ny.eater.com/ramen"}
        ],"total_results":1,"page":0}
        """)
        let store = WebToolStore(defaults: makeDefaults(), keys: InMemoryWebKeyStore())
        store.session = MockURLProtocol.makeSession()

        let outcome = await WebResearch(store: store).run(.init(
            prose: "",
            ops: [.search(query: "ramen", purpose: "dinner", domain: nil, recencyMinutes: nil)],
            failures: []))

        XCTAssertTrue(outcome.producedData)
        XCTAssertTrue(outcome.modelText.hasPrefix("[confabula-web-results]"))
        XCTAssertTrue(outcome.modelText.contains("### search — “ramen”"))
        XCTAssertTrue(outcome.modelText.contains("https://ny.eater.com/ramen"),
                      "the model needs the URL to cite")
        XCTAssertEqual(outcome.ranOps, ["search: ramen"])
    }

    // MARK: - Helpers

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "webtools.tests.\(UUID().uuidString)")!
    }
}

/// In-memory stand-in for the Keychain, so no test touches a real credential.
final class InMemoryWebKeyStore: WebKeyStore {
    private var values: [String: String] = [:]

    func read(_ account: String) -> String? { values[account] }

    func save(_ key: String, account: String) throws { values[account] = key }

    @discardableResult func delete(_ account: String) -> Bool {
        values.removeValue(forKey: account) != nil
    }
}