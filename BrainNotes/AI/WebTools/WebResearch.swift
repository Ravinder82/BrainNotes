import Foundation

/// Runs a bot's web tool block and shapes the outcome into one text turn the
/// model reads before writing its real answer.
///
/// The formatting is deliberately prompt-shaped rather than pretty: what the
/// model gets is a short, dense dossier — sources with URLs, page text with
/// its page named, endpoint prices named before anything is spent — because
/// every character here is spent from the model's context on the one hand and,
/// for Monid runs, from the owner's balance on the other.
@MainActor
struct WebResearch {
    let store: WebToolStore

    /// How many hits one search contributes. Six is enough to cross-check a
    /// claim while keeping the injected payload small.
    static let hitsPerSearch = 6
    /// Extracted page text is clipped per page; one long article must not
    /// crowd out the other pages or the model's own answer.
    static let pageCharacterCap = 1_800
    static let pagesPerFetch = 3
    static let inspectionCharacterCap = 3_000

    struct Outcome {
        /// The text injected as the follow-up turn.
        let modelText: String
        /// Whether anything usable came back. When nothing did, a second pass
        /// would only burn tokens repeating the failure.
        let producedData: Bool
        /// One line per operation, for logs and tests.
        let ranOps: [String]
    }

    /// Execute every operation in a parsed block, in order. Operations are
    /// sequential on purpose: a fetch usually depends on the search before it.
    func run(_ call: WebToolRequest.Call) async -> Outcome {
        guard !call.ops.isEmpty else {
            // No operations at all: the parse problems are the whole story,
            // and they still go back to the model so it can retry properly.
            return Outcome(modelText: problemText(call.failures) ?? "",
                           producedData: false,
                           ranOps: [])
        }

        var sections: [String] = []
        var ranOps: [String] = []
        var producedData = false

        for op in call.ops {
            try? Task.checkCancellation()
            let result = await execute(op)
            sections.append(result.section)
            ranOps.append(result.label)
            producedData = producedData || result.producedData
        }

        var text = "[confabula-web-results]"
        text += "\nThe web tools you requested have run. The results below are fresh from the live web. "
        text += "Ground your answer in them, cite the sources you use as markdown links, and do not "
        text += "claim anything they do not support. If an operation failed or was unavailable, work "
        text += "around it or tell the reader plainly."
        text += "\n\n" + sections.joined(separator: "\n\n")
        if let problems = problemText(call.failures) {
            text += "\n\n" + problems
        }
        return Outcome(modelText: text, producedData: producedData, ranOps: ranOps)
    }

    // MARK: - Operations

    private struct OpResult {
        let label: String
        let section: String
        let producedData: Bool
    }

    private func execute(_ op: WebToolOp) async -> OpResult {
        switch op {
        case .search(let query, let purpose, let domain, let recency):
            return await search(query: query, purpose: purpose, domain: domain, recency: recency)
        case .fetch(let urls, let focus):
            return await fetch(urls: urls, focus: focus)
        case .data(let query):
            return await data(query: query)
        case .inspect(let provider, let endpoint):
            return await inspect(provider: provider, endpoint: endpoint)
        case .run(let provider, let endpoint, let input):
            return await run(provider: provider, endpoint: endpoint, input: input)
        }
    }

    private func search(query: String, purpose: String?, domain: String?, recency: Int?) async -> OpResult {
        let label = "search: \(query)"
        guard store.isActive(.tinyfish) else {
            return unavailable(label, provider: .tinyfish)
        }
        guard let key = store.key(for: .tinyfish) else {
            return unavailable(label, provider: .tinyfish)
        }
        do {
            let client = TinyFishClient(apiKey: key, session: store.session)
            let hits = try await client.search(query: query,
                                               purpose: purpose,
                                               domain: Self.domain(domain),
                                               recencyMinutes: recency)
            guard !hits.isEmpty else {
                return OpResult(label: label,
                                section: "### search — “\(query)”\nNo results were returned.",
                                producedData: false)
            }
            var lines = ["### search — “\(query)”"]
            for hit in hits.prefix(Self.hitsPerSearch) {
                var meta: [String] = []
                if let site = hit.siteName { meta.append(site) }
                if let date = hit.date { meta.append(date) }
                let metaText = meta.isEmpty ? "" : " (\(meta.joined(separator: ", ")))"
                lines.append("\(hit.position ?? 0). \(hit.title) — \(hit.url)\(metaText)")
                if let snippet = hit.snippet, !snippet.isEmpty {
                    lines.append("   \(snippet)")
                }
            }
            return OpResult(label: label, section: lines.joined(separator: "\n"), producedData: true)
        } catch {
            return failed(label, error: error)
        }
    }

    private func fetch(urls: [String], focus: String?) async -> OpResult {
        let label = "fetch: \(urls.count) url(s)"
        guard store.isActive(.tinyfish) else {
            return unavailable(label, provider: .tinyfish)
        }
        guard let key = store.key(for: .tinyfish) else {
            return unavailable(label, provider: .tinyfish)
        }
        do {
            let client = TinyFishClient(apiKey: key, session: store.session)
            let result = try await client.fetch(urls: urls, purpose: focus, query: focus)
            var lines = ["### fetch — \(urls.count) URL(s)"]
            for page in result.pages.prefix(Self.pagesPerFetch) {
                lines.append("**\(page.title ?? page.url)** — \(page.finalURL ?? page.url)")
                if let description = page.description, !description.isEmpty {
                    lines.append("> \(description)")
                }
                lines.append(String(page.text.prefix(Self.pageCharacterCap)))
            }
            for failure in result.failures {
                lines.append("FAILED: \(failure.url) — \(failure.error)")
            }
            let produced = !result.pages.isEmpty
            return OpResult(label: label,
                            section: lines.joined(separator: "\n"),
                            producedData: produced)
        } catch {
            return failed(label, error: error)
        }
    }

    private func data(query: String) async -> OpResult {
        let label = "data: \(query)"
        guard store.isActive(.monid) else {
            return unavailable(label, provider: .monid)
        }
        guard let key = store.key(for: .monid) else {
            return unavailable(label, provider: .monid)
        }
        do {
            let client = MonidClient(apiKey: key, session: store.session)
            let endpoints = try await client.discover(query: query)
            guard !endpoints.isEmpty else {
                return OpResult(label: label,
                                section: "### data — “\(query)”\nNo matching endpoints.",
                                producedData: false)
            }
            var lines = ["### data — “\(query)”",
                         "Candidate endpoints (prices are per run; `inspect` one, then `run` it):"]
            for endpoint in endpoints {
                let price = endpoint.priceLine.map { " · \($0)" } ?? ""
                lines.append("- \(endpoint.provider) · \(endpoint.endpoint)\(price)")
                if !endpoint.description.isEmpty {
                    lines.append("  \(endpoint.description)")
                }
            }
            return OpResult(label: label, section: lines.joined(separator: "\n"), producedData: true)
        } catch {
            return failed(label, error: error)
        }
    }

    private func inspect(provider: String, endpoint: String) async -> OpResult {
        let label = "inspect: \(provider)\(endpoint)"
        guard store.isActive(.monid) else {
            return unavailable(label, provider: .monid)
        }
        guard let key = store.key(for: .monid) else {
            return unavailable(label, provider: .monid)
        }
        do {
            let client = MonidClient(apiKey: key, session: store.session)
            let schema = try await client.inspect(provider: provider, endpoint: endpoint)
            let text = String(schema.prefix(Self.inspectionCharacterCap))
            return OpResult(label: label,
                            section: "### inspect — \(provider)\(endpoint)\n```json\n\(text)\n```",
                            producedData: true)
        } catch {
            return failed(label, error: error)
        }
    }

    private func run(provider: String, endpoint: String, input: [String: AnyJSON]) async -> OpResult {
        let label = "run: \(provider)\(endpoint)"
        guard store.isActive(.monid) else {
            return unavailable(label, provider: .monid)
        }
        guard let key = store.key(for: .monid) else {
            return unavailable(label, provider: .monid)
        }
        do {
            let client = MonidClient(apiKey: key, session: store.session)
            let result = try await client.run(provider: provider,
                                              endpoint: endpoint,
                                              input: input)
            var lines = ["### run — \(provider)\(endpoint)",
                         result.summaryLine]
            if let billed = result.billedUnits {
                lines.append("Billed units: \(billed)")
            }
            if !result.outputJSON.isEmpty {
                lines.append("```json\n\(result.outputJSON)\n```")
            }
            return OpResult(label: label,
                            section: lines.joined(separator: "\n"),
                            producedData: result.succeeded && !result.outputJSON.isEmpty)
        } catch {
            return failed(label, error: error)
        }
    }

    // MARK: - Shared shapes

    private func unavailable(_ label: String, provider: WebProviderID) -> OpResult {
        OpResult(label: label,
                 section: "### \(label)\nTOOL UNAVAILABLE: \(provider.displayName) is switched off or has no key. "
                        + "Answer without it, or say what is missing.",
                 producedData: false)
    }

    private func failed(_ label: String, error: Error) -> OpResult {
        let message = (error as? WebToolError)?.modelFacing ?? error.localizedDescription
        return OpResult(label: label,
                        section: "### \(label)\n\(message)",
                        producedData: false)
    }

    private func problemText(_ failures: [String]) -> String? {
        guard !failures.isEmpty else { return nil }
        return "Block problems:\n" + failures.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func domain(_ raw: String?) -> TinyFishClient.DomainType {
        switch raw {
        case "news":          return .news
        case "research_paper", "papers", "paper", "research": return .researchPaper
        default:              return .web
        }
    }
}