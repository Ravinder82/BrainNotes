import Foundation

/// Monid: one key in front of hundreds of pay-per-run data endpoints.
///
/// The API is a three-step ladder, and the bot prompt teaches the same ladder:
///
/// - `POST /v1/discover` — find candidate endpoints for a plain-language need.
/// - `POST /v1/inspect`  — read one endpoint's full input schema.
/// - `POST /v1/run`      — execute it; answers inline, or `202` plus a run id
///   that is polled to completion.
///
/// Runs are billed from the account balance, so the app puts the balance on
/// the settings card and states prices in every discovery result — a bot (and
/// its owner) should never spend without the number on screen.
///
/// One wire subtlety drives the shape of `run`: a *synchronous* run mirrors
/// the provider's HTTP status, so `404`/`429`/`500` still carry a valid run
/// envelope whose `status` is `COMPLETED` and whose `providerResponse` holds
/// the real story. Transport errors are therefore decided by whether the body
/// parses as a run at all, not by the status code alone.
struct MonidClient {
    static let baseURL = "https://api.monid.ai/v1"

    /// How long a single run may take end to end before the pass gives up.
    /// Monid documents most runs completing within 1–120 seconds.
    static let defaultRunTimeout: TimeInterval = 120
    static let defaultPollInterval: TimeInterval = 3

    /// Keeps one runaway endpoint from dumping a megabyte into a prompt.
    static let outputCharacterCap = 6_000

    let apiKey: String
    var session: URLSession = OpenAIClient.sharedSession

    // MARK: - Wallet

    /// Read the account balance. Doubles as the cheapest authentication probe:
    /// it touches no paid endpoint but still requires a valid key.
    func balance() async throws -> MonidBalance {
        var request = URLRequest(url: try Self.url(Self.baseURL + "/wallet/balance"))
        request.httpMethod = "GET"
        Self.authorize(&request, apiKey)

        let data = try await perform(request, provider: "Monid")
        guard let envelope = try? JSONDecoder().decode(BalanceEnvelope.self, from: data) else {
            throw WebToolError.decoding("balance")
        }
        return MonidBalance(value: envelope.balance.value, currency: envelope.balance.currency)
    }

    // MARK: - Discover

    /// Candidate endpoints for a plain-language need, best match first.
    func discover(query: String, limit: Int = 5) async throws -> [MonidEndpointRef] {
        let data = try await post("/discover", body: ["query": query, "limit": limit])
        guard let envelope = try? JSONDecoder().decode(DiscoverEnvelope.self, from: data) else {
            throw WebToolError.decoding("discover")
        }
        return envelope.results.compactMap { row in
            guard let provider = row.provider, let endpoint = row.endpoint else { return nil }
            return MonidEndpointRef(provider: provider,
                                    providerName: row.providerName,
                                    endpoint: endpoint,
                                    description: row.description ?? "",
                                    score: row.score,
                                    priceLine: Self.priceLine(row.price))
        }
    }

    // MARK: - Inspect

    /// What an endpoint does and the exact input schema it expects, as pretty
    /// JSON text. Passed to the model verbatim: the schema is what lets it
    /// build a correct `run` input instead of guessing field names.
    ///
    /// The raw response also carries vendor metadata and a full base URL that
    /// no model needs, so it is narrowed to the working parts here.
    func inspect(provider: String, endpoint: String) async throws -> String {
        let data = try await post("/inspect", body: ["provider": provider, "endpoint": endpoint])
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebToolError.decoding("inspect")
        }
        var focused: [String: Any] = [:]
        for key in ["provider", "endpoint", "description", "summary", "method", "input", "price"] {
            if let value = object[key] { focused[key] = value }
        }
        return Self.prettyJSON(focused.isEmpty ? object : focused)
    }

    // MARK: - Run

    /// Execute an endpoint and wait for its output.
    ///
    /// Sync endpoints return their payload inline — provider errors included.
    /// Async endpoints answer `202` with a run id, which is polled until a
    /// terminal status or `timeout`, whichever comes first.
    func run(provider: String,
             endpoint: String,
             input: [String: AnyJSON],
             pollInterval: TimeInterval = MonidClient.defaultPollInterval,
             timeout: TimeInterval = MonidClient.defaultRunTimeout) async throws -> MonidRunResult {
        var body: [String: Any] = ["provider": provider, "endpoint": endpoint]
        // The sendable box becomes plain JSON only here, inside the client —
        // so a dictionary the model wrote never crosses an actor boundary.
        if !input.isEmpty { body["input"] = input.mapValues(\.value) }

        var request = URLRequest(url: try Self.url(Self.baseURL + "/run"))
        request.httpMethod = "POST"
        Self.authorize(&request, apiKey)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let (data, statusCode) = try await sessionData(request)
        guard let envelope = try? JSONDecoder().decode(RunEnvelope.self, from: data) else {
            // Not a run envelope: an auth, balance, or gateway error body.
            guard (200..<300).contains(statusCode) else {
                throw WebToolError.http(statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            throw WebToolError.decoding("run")
        }

        // Finished inline (sync providers, and control-gate BLOCKED).
        if let done = Self.finishedRun(envelope, provider: provider, endpoint: endpoint) {
            return done
        }

        guard let runID = envelope.runID else {
            throw WebToolError.decoding("run (no run id and no inline output)")
        }
        return try await poll(runID: runID, provider: provider, endpoint: endpoint,
                              interval: pollInterval, timeout: timeout)
    }

    /// Poll a queued/running run to a terminal state.
    private func poll(runID: String,
                      provider: String,
                      endpoint: String,
                      interval: TimeInterval,
                      timeout: TimeInterval) async throws -> MonidRunResult {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))

            var request = URLRequest(url: try Self.url(Self.baseURL + "/runs/\(runID)"))
            request.httpMethod = "GET"
            Self.authorize(&request, apiKey)
            let data = try await perform(request, provider: "Monid")
            guard let envelope = try? JSONDecoder().decode(RunEnvelope.self, from: data) else {
                throw WebToolError.decoding("run status")
            }

            if let status = envelope.status?.uppercased(),
               Self.terminalStatuses.contains(status) {
                return Self.result(from: envelope, runID: runID,
                                   provider: provider, endpoint: endpoint, status: status)
            }
        }
        throw WebToolError.timedOut("Monid run \(runID)")
    }

    // MARK: - Wire

    private struct BalanceEnvelope: Decodable {
        let balance: Money
        struct Money: Decodable {
            let value: Double
            let currency: String
        }
    }

    private struct DiscoverEnvelope: Decodable {
        let results: [Row]

        struct Row: Decodable {
            let provider: String?
            let providerName: String?
            let endpoint: String?
            let description: String?
            let score: Double?
            let price: Price?
        }

        struct Price: Decodable {
            let type: String?
            let amount: Money?
            struct Money: Decodable {
                let value: Double?
                let currency: String?
            }
            /// Deeper `notes` arrays are price nuance a candidate list doesn't
            /// need; the number and cadence are enough.
        }
    }

    /// One envelope serves the sync response, the async acknowledgement, and
    /// the polled status — only which fields are present differs.
    private struct RunEnvelope: Decodable {
        let runID: String?
        let status: String?
        let output: AnyJSON?
        let reason: String?
        let providerResponse: ProviderResponse?
        let billedUnits: Int?

        enum CodingKeys: String, CodingKey {
            case runID = "runId"
            case status, output, reason, providerResponse, billedUnits
        }

        struct ProviderResponse: Decodable {
            let httpStatus: Int?
            let error: ProviderError?

            struct ProviderError: Decodable {
                let status: Int?
                let message: String?
            }
        }
    }

    /// Statuses after which no further polling can change the outcome.
    private static let terminalStatuses: Set<String> = [
        "COMPLETED", "FAILED", "BLOCKED", "STOPPED", "TIMED_OUT"
    ]

    /// A run that already has its outcome: sync completions and control-gate
    /// rejections both arrive without a run to poll.
    private static func finishedRun(_ envelope: RunEnvelope,
                                    provider: String,
                                    endpoint: String) -> MonidRunResult? {
        guard let status = envelope.status?.uppercased() else { return nil }
        if terminalStatuses.contains(status) {
            return result(from: envelope, runID: envelope.runID,
                          provider: provider, endpoint: endpoint, status: status)
        }
        return nil
    }

    private static func result(from envelope: RunEnvelope,
                               runID: String?,
                               provider: String,
                               endpoint: String,
                               status: String) -> MonidRunResult {
        MonidRunResult(runID: runID,
                       provider: provider,
                       endpoint: endpoint,
                       status: status,
                       providerHTTPStatus: envelope.providerResponse?.httpStatus,
                       providerErrorMessage: envelope.providerResponse?.error?.message,
                       reason: envelope.reason,
                       billedUnits: envelope.billedUnits,
                       outputJSON: outputText(envelope.output) ?? "")
    }

    private static func outputText(_ output: AnyJSON?) -> String? {
        guard let output, output != .null else { return nil }
        let text = prettyJSON(output.value)
        guard text.count > outputCharacterCap else { return text }
        return String(text.prefix(outputCharacterCap)) + "\n…(truncated)"
    }

    private static func prettyJSON(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return String(describing: object) }
        return text
    }

    private static func priceLine(_ price: DiscoverEnvelope.Price?) -> String? {
        guard let price, let amount = price.amount, let value = amount.value, value > 0 else { return nil }
        let unit: String
        switch (price.type ?? "").uppercased() {
        case "PER_CALL":   unit = "per call"
        case "PER_RESULT": unit = "per result"
        case "PER_URL":    unit = "per URL"
        case "PER_ITEM":   unit = "per item"
        default:           unit = (price.type ?? "per run").lowercased().replacingOccurrences(of: "_", with: " ")
        }
        // Trailing zeros make a price look more expensive than it is: $0.0010
        // reads worse than $0.001.
        var amountText = String(format: "%.4f", value)
        while amountText.hasSuffix("0") && !amountText.hasSuffix(".0") {
            amountText.removeLast()
        }
        return "$\(amountText) \(unit)"
    }

    private func post(_ path: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: try Self.url(Self.baseURL + path))
        request.httpMethod = "POST"
        Self.authorize(&request, apiKey)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30
        return try await perform(request, provider: "Monid")
    }

    private static func authorize(_ request: inout URLRequest, _ apiKey: String) {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    private static func url(_ string: String) throws -> URL {
        guard let url = URL(string: string) else { throw WebToolError.badURL(string) }
        return url
    }

    /// Transport for endpoints whose failures are transport failures.
    private func perform(_ request: URLRequest, provider: String) async throws -> Data {
        let (data, statusCode) = try await sessionData(request)
        guard (200..<300).contains(statusCode) || statusCode == 202 else {
            throw WebToolError.http(statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// Raw transport: status and body, no interpretation — `run` decides for
    /// itself whether a non-2xx body is an error or a completed-but-empty run.
    private func sessionData(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebToolError.decoding("no HTTP response from Monid")
        }
        return (data, http.statusCode)
    }
}

/// Any-JSON box, so a provider payload survives decoding when its exact shape
/// is not part of the contract — run outputs vary per endpoint by design.
enum AnyJSON: Decodable, Equatable, Sendable {
    case object([String: AnyJSON])
    case array([AnyJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: AnyJSON].self) {
            self = .object(value)
        } else if let value = try? container.decode([AnyJSON].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    /// Boxes an already-parsed Foundation value — used for inputs a model
    /// supplied as raw JSON in a tool block.
    init(any: Any) {
        switch any {
        case let dict as [String: Any]: self = .object(dict.mapValues(AnyJSON.init(any:)))
        case let list as [Any]:          self = .array(list.map(AnyJSON.init(any:)))
        case let bool as Bool:           self = .bool(bool)
        case let number as NSNumber:     self = .number(number.doubleValue)
        case let string as String:       self = .string(string)
        default:                         self = .null
        }
    }

    /// Plain Foundation value, ready for `JSONSerialization`.
    var value: Any {
        switch self {
        case .object(let dict): return dict.mapValues(\.value)
        case .array(let list):  return list.map(\.value)
        case .string(let s):    return s
        case .number(let n):    return n
        case .bool(let b):      return b
        case .null:             return NSNull()
        }
    }
}