import Foundation

// MARK: - Normalized results
//
// The app speaks two dialects: TinyFish (free web search + page extraction)
// and Monid (discover → inspect → run against hundreds of data endpoints).
// Every bot-facing surface — the prompt section, the research pass, the
// settings test buttons — reads one vocabulary, so each client maps its wire
// shape into these types at the boundary instead of leaking provider JSON
// into the engine.

/// One ranked web-search hit. Identifiable by URL so a results list can be
/// fed straight into `fetch` without re-deriving identity.
struct WebSearchHit: Codable, Equatable, Identifiable {
    var id: String { url }
    let title: String
    let url: String
    let siteName: String?
    let snippet: String?
    let date: String?
    let position: Int?
}

/// One extracted page. `text` is the clean markdown (or HTML/JSON) the
/// provider returns, already stripped of boilerplate by the extractor.
struct WebFetchPage: Codable, Equatable {
    let url: String
    let finalURL: String?
    let title: String?
    let description: String?
    let language: String?
    let text: String
}

/// A per-URL fetch failure. The fetch endpoint answers `200` even when some
/// URLs fail, so these travel alongside successful pages rather than throwing.
struct WebFetchFailure: Codable, Equatable {
    let url: String
    let error: String
}

/// A data endpoint Monid can run, as returned by `discover`.
struct MonidEndpointRef: Codable, Equatable, Identifiable {
    var id: String { "\(provider)\(endpoint)" }
    let provider: String
    let providerName: String?
    let endpoint: String
    let description: String
    let score: Double?
    /// Pre-formatted price line ("$0.003 per call"), when the provider publishes one.
    let priceLine: String?

    /// "Apify · /apidojo/tweet-scraper" — one line for the prompt and for logs.
    var displayName: String {
        "\(providerName ?? provider) · \(endpoint)"
    }
}

/// Wallet balance, the cheapest proof that a Monid key authenticates.
struct MonidBalance: Equatable {
    let value: Double
    let currency: String

    var formatted: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value))
            ?? "\(value) \(currency)"
    }
}

/// The outcome of one Monid run, normalized across sync and async execution.
/// `outputJSON` is the provider's payload re-encoded as text, already
/// truncated for prompt injection.
///
/// Two independent indicators travel together, per Monid's contract: the run
/// lifecycle (`status`) and the *data provider's* HTTP status. A run can be
/// `COMPLETED` with a `404` from the provider — a normal "no data" outcome
/// that costs nothing and that a bot should be told, not shielded from.
struct MonidRunResult: Equatable {
    let runID: String?
    let provider: String
    let endpoint: String
    /// Lifecycle status: COMPLETED, FAILED, BLOCKED, STOPPED, TIMED_OUT.
    let status: String
    /// The provider's own HTTP status, when the run reached the provider.
    let providerHTTPStatus: Int?
    /// The provider's error message, when the provider returned one.
    let providerErrorMessage: String?
    /// Why a control gate blocked the run (`BLOCKED` only).
    let reason: String?
    let billedUnits: Int?
    let outputJSON: String

    /// True only when the run finished and the provider answered 2xx.
    var succeeded: Bool {
        status == "COMPLETED" && (providerHTTPStatus.map { (200..<300).contains($0) } ?? true)
    }

    /// One line a bot can act on, whichever way the run went.
    var summaryLine: String {
        var parts = ["\(provider)\(endpoint) → \(status)"]
        if let providerHTTPStatus { parts.append("provider HTTP \(providerHTTPStatus)") }
        if let reason { parts.append(reason) }
        if let providerErrorMessage { parts.append(providerErrorMessage) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Errors

/// Failures shared by both clients.
///
/// Messages are written for the chat surface, not for a console: when a bot's
/// research pass fails, this text is what the model is told to work around.
enum WebToolError: LocalizedError {
    /// The provider has no key on file.
    case missingKey(String)
    case badURL(String)
    case http(Int, String)
    case decoding(String)
    case empty(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let provider):
            return "No \(provider) API key is set. Add one in Settings → Web Search & Data."
        case .badURL(let s):
            return "Invalid web tools URL: \(s)"
        case .http(let code, let body):
            switch code {
            case 401, 403: return "Web tools authentication failed (\(code)). Check the API key."
            case 402:      return "Web tools provider reports the account is out of balance (402)."
            case 429:      return "Web tools rate limited (429). Try again shortly."
            case 400:      return "Web tools rejected the request (400). \(body.wireSnippet())"
            case 404:      return "Web tools endpoint not found (404). \(body.wireSnippet())"
            case 500...599: return "Web tools provider error (\(code)). \(body.wireSnippet())"
            default:       return "Web tools request failed (\(code)). \(body.wireSnippet())"
            }
        case .decoding(let m):
            return "Could not read the web tools response: \(m)"
        case .empty(let provider):
            return "\(provider) returned an empty response."
        case .timedOut(let what):
            return "\(what) timed out."
        }
    }

    /// A copy phrased for a *model* rather than a person: it is injected into
    /// the research pass so the bot can explain the failure or try another op.
    var modelFacing: String {
        switch self {
        case .missingKey(let provider):
            return "TOOL UNAVAILABLE: no \(provider) key configured."
        case .timedOut(let what):
            return "TOOL ERROR: \(what) timed out."
        default:
            return "TOOL ERROR: \(errorDescription ?? "unknown failure")"
        }
    }
}

extension String {
    /// Trims and clips a wire body for an error message.
    func wireSnippet(_ n: Int = 180) -> String {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= n ? t : String(t.prefix(n)) + "…"
    }
}