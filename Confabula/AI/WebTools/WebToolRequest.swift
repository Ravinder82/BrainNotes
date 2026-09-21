import Foundation

/// The app's contract with a bot that needs the live web.
///
/// Bots run on the lowest-common-denominator chat API — plain streaming text,
/// no provider-native tool calls — so "use a tool" is expressed the same way
/// Captain's crew actions already are: a fenced JSON block the app lifts out
/// of the reply, executes, and answers with results. The model then writes its
/// real answer knowing what the web said.
///
/// The block never reaches the reader. `MessageBubble` renders `prose` only,
/// and `ChatEngine` strips the fence from every persisted reply whether or not
/// the tools ran, so a bot that emits a block with the providers switched off
/// degrades to plain text instead of leaking machine syntax into the chat.
///
///     ```confabula-web
///     {"ops":[{"op":"search","query":"berlin ai act status","domain":"news"}]}
///     ```
enum WebToolRequest {
    /// The fence that opens a tool block.
    static let fence = "```confabula-web"

    /// More than this in one block would make a single reply wait on several
    /// slow endpoints; a bot can always emit a second block after seeing the
    /// first round of results.
    static let maxOps = 3

    // MARK: - Parse

    /// A parsed block: the human prose, the operations to run, and any
    /// operations that could not be read (reported back to the model instead
    /// of silently dropped).
    struct Call: Equatable {
        var prose: String
        var ops: [WebToolOp]
        var failures: [String]
    }

    /// `nil` when the reply carries no block at all.
    static func parse(_ text: String) -> Call? {
        guard let block = blockRange(in: text) else { return nil }
        let payload = String(text[block.payload])
        let prose = proseByRemoving(block.full, from: text)
        return decode(payload, prose: prose)
    }

    /// Removes every tool block, leaving trimmed prose. Used on the text that
    /// is persisted, so no path can show the fence to a reader.
    static func stripBlocks(_ text: String) -> String {
        var result = text
        while let block = blockRange(in: result) {
            result.removeSubrange(block.full)
        }
        return tidy(result)
    }

    // MARK: - Decode

    private static func decode(_ payload: String, prose: String) -> Call {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return Call(prose: prose, ops: [],
                        failures: ["The web tool block was not valid JSON."])
        }

        // One block may hold a single operation or a list. A bare array is
        // accepted too, since models reach for whichever shape they saw last.
        let rows: [Any]
        if let list = object as? [Any] {
            rows = list
        } else if let dict = object as? [String: Any] {
            if let list = dict["ops"] as? [Any] {
                rows = list
            } else if let list = dict["operations"] as? [Any] {
                rows = list
            } else {
                rows = [dict]
            }
        } else {
            return Call(prose: prose, ops: [], failures: ["The web tool block had no operations."])
        }

        var ops: [WebToolOp] = []
        var failures: [String] = []
        for row in rows.prefix(maxOps) {
            guard let dict = row as? [String: Any] else {
                failures.append("One entry in the web tool block was not an object.")
                continue
            }
            switch WebToolOp.parse(dict: dict) {
            case .success(let op): ops.append(op)
            case .failure(let error): failures.append(error.message)
            }
        }
        if rows.count > maxOps {
            failures.append("Only the first \(maxOps) operations in a block are run; emit another block if you need more.")
        }
        return Call(prose: prose, ops: ops, failures: failures)
    }

    // MARK: - Fence surgery

    /// Where a block sits, split so callers can lift the payload out and cut
    /// the whole block (fence included) from the prose.
    private struct Block {
        var full: Range<String.Index>
        var payload: Range<String.Index>
    }

    private static func blockRange(in text: String) -> Block? {
        guard let opening = text.range(of: fence) else { return nil }
        let afterMarker = text[opening.upperBound...]
        guard let firstLine = afterMarker.firstRange(of: "\n"),
              let closing = afterMarker[firstLine.upperBound...].range(of: "```")
        else { return nil }
        return Block(full: opening.lowerBound..<closing.upperBound,
                     payload: firstLine.upperBound..<closing.lowerBound)
    }

    private static func proseByRemoving(_ range: Range<String.Index>, from text: String) -> String {
        var prose = text
        prose.removeSubrange(range)
        return tidy(prose)
    }

    /// The removed block usually sat on its own line between paragraphs;
    /// without collapsing, the bubble shows a blank canyon where it was.
    private static func tidy(_ text: String) -> String {
        var prose = text
        while let gap = prose.range(of: "\n\n\n") {
            prose.replaceSubrange(gap, with: "\n\n")
        }
        return prose.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Operations

/// One thing a bot asked the web to do.
enum WebToolOp: Equatable {
    /// Ranked web results. `domain` is `web`, `news`, or `research_paper`.
    case search(query: String, purpose: String?, domain: String?, recencyMinutes: Int?)
    /// Extract clean text from URLs the model already has.
    case fetch(urls: [String], focus: String?)
    /// Find paid data endpoints for needs search cannot serve.
    case data(query: String)
    /// Read one endpoint's input schema before spending on it.
    case inspect(provider: String, endpoint: String)
    /// Execute a data endpoint with a schema-shaped input.
    case run(provider: String, endpoint: String, input: [String: AnyJSON])

    /// Why one operation could not be read. Handed back to the model, which
    /// usually has the argument it forgot and can fix it in the next block.
    struct ParseFailure: Error, Equatable {
        let message: String
    }

    /// Reads one operation, validating the arguments it cannot run without.
    /// A malformed op becomes a note to the model instead of a doomed request.
    static func parse(dict: [String: Any]) -> Result<WebToolOp, ParseFailure> {
        let op = (dict["op"] as? String ?? dict["operation"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        func text(_ key: String) -> String? {
            (dict[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        switch op {
        case "search":
            guard let query = text("query"), !query.isEmpty else {
                return .failure(ParseFailure(message: "A `search` operation needs a non-empty `query`."))
            }
            let domain = (text("domain") ?? text("domain_type"))?.lowercased()
            return .success(.search(query: query,
                                    purpose: text("purpose"),
                                    domain: domain,
                                    recencyMinutes: (dict["recency_minutes"] as? NSNumber)?.intValue))
        case "fetch":
            let urls = (dict["urls"] as? [String]) ?? text("url").map { [$0] } ?? []
            let cleaned = urls.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !cleaned.isEmpty else {
                return .failure(ParseFailure(message: "A `fetch` operation needs `urls` (or `url`)."))
            }
            return .success(.fetch(urls: cleaned, focus: text("focus") ?? text("query")))
        case "data", "discover":
            guard let query = text("query"), !query.isEmpty else {
                return .failure(ParseFailure(message: "A `data` operation needs a non-empty `query`."))
            }
            return .success(.data(query: query))
        case "inspect":
            guard let provider = text("provider"), !provider.isEmpty,
                  let endpoint = text("endpoint"), !endpoint.isEmpty else {
                return .failure(ParseFailure(message: "An `inspect` operation needs `provider` and `endpoint`."))
            }
            return .success(.inspect(provider: provider, endpoint: endpoint))
        case "run":
            guard let provider = text("provider"), !provider.isEmpty,
                  let endpoint = text("endpoint"), !endpoint.isEmpty else {
                return .failure(ParseFailure(message: "A `run` operation needs `provider` and `endpoint`."))
            }
            let input = (dict["input"] as? [String: Any])?.mapValues(AnyJSON.init(any:)) ?? [:]
            return .success(.run(provider: provider, endpoint: endpoint, input: input))
        default:
            let named = op.isEmpty ? "one with no `op` field" : "`\(op)`"
            return .failure(ParseFailure(
                message: "Unknown operation \(named). Use one of: search, fetch, data, inspect, run."))
        }
    }
}

// MARK: - Prompt section

/// The system-prompt section that teaches a bot the block format, written to
/// be included only for the providers the owner actually enabled — a bot told
/// about tools it does not have is a bot that promises research it cannot do.
enum WebAccessPrompt {
    static func section(tinyfish: Bool, monid: Bool) -> String? {
        guard tinyfish || monid else { return nil }

        var lines: [String] = [
            "WEB ACCESS — you have live web tools. Use them when a task needs current facts, prices, news, sources, or the contents of a page you do not already know. Never invent sources or present stale memory as fresh data.",
            "",
            "To use them, emit one fenced block in your reply:",
            "```confabula-web",
            tinyfish ? #"{"ops":[{"op":"search","query":"…","purpose":"why you need this"}]}"#
                     : #"{"ops":[{"op":"data","query":"what you need data for"}]}"#,
            "```",
            "",
            "Operations you have (at most \(WebToolRequest.maxOps) per block):"
        ]

        if tinyfish {
            lines.append("- `search` — search the web. Args: `query` (required), `purpose` (a short reason; it sharpens ranking), `domain` one of `web` | `news` | `research_paper`, `recency_minutes` for breaking coverage.")
            lines.append("- `fetch` — extract clean text from up to 10 URLs you already have. Args: `urls` (required), `focus` (keywords to return just the relevant passages).")
        }
        if monid {
            lines.append("- `data` — find paid data endpoints for what search cannot serve (social posts, profiles, reviews, listings). Arg: `query`. Returns candidates with prices.")
            lines.append("- `inspect` — read one endpoint's exact input schema. Args: `provider`, `endpoint`. Always inspect before a first run.")
            lines.append("- `run` — execute a data endpoint. Args: `provider`, `endpoint`, `input` (must match the inspected schema). Runs spend from the account balance, so say what you are buying in your prose.")
        }

        lines.append("")
        lines.append("After you emit the block, the app runs the operations and sends you the results in the conversation; then write your real answer, citing the sources you used as markdown links. Emit a block only when the task genuinely needs live data — not for greetings, opinions, or anything you already know. If the block is missing required arguments, or the tools do not cover the task, answer with what you have and say so plainly.")

        return lines.joined(separator: "\n")
    }
}