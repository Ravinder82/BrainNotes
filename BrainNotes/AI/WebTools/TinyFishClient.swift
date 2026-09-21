import Foundation

/// TinyFish: free web search and page extraction.
///
/// Two independent surfaces, both on this one key:
///
/// - `GET  https://api.search.tinyfish.ai?query=…` — ranked hits with
///   snippets; the app's web search.
/// - `POST https://api.fetch.tinyfish.ai` — up to 10 URLs per call, returned
///   as clean markdown; the app's extraction ("read this page for me").
///
/// Both are `$0.00`: search is free per request, fetch is free per URL, so a
/// bot can research without the app touching a wallet. TinyFish also sells
/// browser automation and agent runs, but those draw from a balance and are
/// deliberately not wired here — a chat bot's job is to know, not to act.
struct TinyFishClient {
    static let searchURL = "https://api.search.tinyfish.ai"
    static let fetchURL = "https://api.fetch.tinyfish.ai"

    /// How many hits the app asks for by default. Eight is enough for a bot
    /// to cross-check a claim while keeping the injected prompt payload small.
    static let defaultSearchLimit = 8
    static let maxFetchURLs = 10

    let apiKey: String
    var session: URLSession = OpenAIClient.sharedSession

    /// What pool of documents to search. Research papers ignore recency and
    /// are scoped by publication year instead.
    enum DomainType: String, Sendable {
        case web
        case news
        case researchPaper = "research_paper"
    }

    // MARK: - Search

    /// Ranked web results for `query`.
    ///
    /// `purpose` is TinyFish's intent signal — a short sentence about why the
    /// search is happening measurably improves ranking, so callers pass the
    /// bot's actual goal rather than the bare query.
    func search(query: String,
                purpose: String? = nil,
                domain: DomainType = .web,
                recencyMinutes: Int? = nil,
                page: Int = 0) async throws -> [WebSearchHit] {
        var items: [URLQueryItem] = [URLQueryItem(name: "query", value: query)]
        if let purpose, !purpose.isEmpty {
            items.append(URLQueryItem(name: "purpose", value: purpose))
        }
        items.append(URLQueryItem(name: "domain_type", value: domain.rawValue))
        if let recencyMinutes, domain != .researchPaper {
            items.append(URLQueryItem(name: "recency_minutes", value: String(recencyMinutes)))
        }
        if page > 0 {
            items.append(URLQueryItem(name: "page", value: String(page)))
        }

        var components = URLComponents(string: Self.searchURL)
        components?.queryItems = items
        guard let url = components?.url else {
            throw WebToolError.badURL(Self.searchURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 30

        let data = try await perform(request, provider: "TinyFish")
        return try decodeSearchEnvelope(data)
    }

    // MARK: - Fetch

    /// Extract clean content from up to 10 URLs.
    ///
    /// Answers `200` even when individual URLs fail, so failures are returned
    /// alongside pages rather than thrown — one dead link must not sink a
    /// five-source research pass.
    func fetch(urls: [String],
               format: String = "markdown",
               purpose: String? = nil,
               query: String? = nil) async throws -> (pages: [WebFetchPage], failures: [WebFetchFailure]) {
        let urls = Array(urls.prefix(Self.maxFetchURLs))
        guard !urls.isEmpty else {
            throw WebToolError.empty("TinyFish fetch")
        }

        var body: [String: Any] = ["urls": urls, "format": format]
        if let purpose, !purpose.isEmpty { body["purpose"] = purpose }
        // A query switches the extractor to relevance highlights instead of
        // whole-page content — useful when a bot wants one number off a page.
        if let query, !query.isEmpty { body["query"] = query }

        var request = URLRequest(url: try Self.url(Self.fetchURL))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let data = try await perform(request, provider: "TinyFish")
        return try decodeFetchEnvelope(data)
    }

    // MARK: - Wire

    private struct SearchEnvelope: Decodable {
        let results: [Hit]

        struct Hit: Decodable {
            let title: String?
            let url: String?
            let siteName: String?
            let snippet: String?
            let date: String?
            let position: Int?

            enum CodingKeys: String, CodingKey {
                case title, url, snippet, date, position
                case siteName = "site_name"
            }
        }
    }

    private struct FetchEnvelope: Decodable {
        let results: [Page]
        let errors: [Failure]?

        struct Page: Decodable {
            let url: String?
            let finalURL: String?
            let title: String?
            let description: String?
            let language: String?
            let text: String?

            enum CodingKeys: String, CodingKey {
                case url, title, description, language, text
                case finalURL = "final_url"
            }
        }

        struct Failure: Decodable {
            let url: String?
            let error: String?
        }
    }

    private func decodeSearchEnvelope(_ data: Data) throws -> [WebSearchHit] {
        do {
            let envelope = try JSONDecoder().decode(SearchEnvelope.self, from: data)
            // Rows missing a URL can't be fetched or cited; drop them rather
            // than surface half-rows to a bot.
            return envelope.results.compactMap(Self.hit)
        } catch {
            throw WebToolError.decoding("search results (\(error.localizedDescription))")
        }
    }

    private func decodeFetchEnvelope(_ data: Data) throws -> (pages: [WebFetchPage], failures: [WebFetchFailure]) {
        do {
            let envelope = try JSONDecoder().decode(FetchEnvelope.self, from: data)
            let pages = envelope.results.compactMap { page -> WebFetchPage? in
                guard let url = page.url else { return nil }
                return WebFetchPage(url: url,
                                    finalURL: page.finalURL,
                                    title: page.title,
                                    description: page.description,
                                    language: page.language,
                                    text: page.text ?? "")
            }
            let failures = (envelope.errors ?? []).map {
                WebFetchFailure(url: $0.url ?? "", error: $0.error ?? "fetch failed")
            }
            return (pages, failures)
        } catch {
            throw WebToolError.decoding("fetch results (\(error.localizedDescription))")
        }
    }

    private static func hit(_ row: SearchEnvelope.Hit) -> WebSearchHit? {
        guard let url = row.url, !url.isEmpty else { return nil }
        return WebSearchHit(title: row.title ?? url,
                            url: url,
                            siteName: row.siteName,
                            snippet: row.snippet,
                            date: row.date,
                            position: row.position)
    }

    private static func url(_ string: String) throws -> URL {
        guard let url = URL(string: string) else { throw WebToolError.badURL(string) }
        return url
    }

    /// Shared transport: status-check, then hand the caller the body.
    private func perform(_ request: URLRequest, provider: String) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebToolError.decoding("no HTTP response from \(provider)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WebToolError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}