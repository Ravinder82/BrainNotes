import Foundation

/// One turn in the wire protocol. `content` is either a plain string or an
/// array of multimodal parts (see `wireContent`), so the same type carries
/// text-only and image messages.
struct ChatTurn: Codable {
    let role: String  // "system" | "user" | "assistant"
    let content: String
    /// Base64 data URL for an attached image, when the turn has one.
    var imageDataURL: String?

    init(role: String, content: String, imageDataURL: String? = nil) {
        self.role = role
        self.content = content
        self.imageDataURL = imageDataURL
    }

    /// OpenAI-compatible `messages[].content`, promoted to the multimodal
    /// array form when an image is present.
    var wireContent: Any {
        guard let imageDataURL else { return content }
        var parts: [[String: Any]] = []
        if !content.isEmpty {
            parts.append(["type": "text", "text": content])
        }
        parts.append([
            "type": "image_url",
            "image_url": ["url": imageDataURL],
        ])
        return parts
    }
}

enum AIError: LocalizedError {
    case notConfigured
    case badURL(String)
    case http(Int, String)
    case empty
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No API key set. Open Settings and add one."
        case .badURL(let s):
            return "Invalid base URL: \(s)"
        case .http(let code, let body):
            switch code {
            case 401, 403: return "Authentication failed (\(code)). Check your API key."
            case 404:      return "Model or endpoint not found (404). \(body.snippet())"
            case 429:      return "Rate limited (429). Try again shortly."
            case 400:      return "Bad request (400). \(body.snippet())"
            case 500...599: return "Provider error (\(code)). \(body.snippet())"
            default:       return "Request failed (\(code)). \(body.snippet())"
            }
        case .empty:
            return "The provider returned an empty response."
        case .decoding(let m):
            return "Could not read the response: \(m)"
        }
    }
}

private extension String {
    func snippet(_ n: Int = 180) -> String {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= n ? t : String(t.prefix(n)) + "…"
    }
}

/// Minimal OpenAI-compatible chat client. Uses `POST {base}/chat/completions`
/// with SSE streaming, which is the common denominator across OpenAI,
/// OpenRouter, Groq, Together, Ollama, LM Studio, vLLM and friends.
struct OpenAIClient {
    let baseURL: String
    let apiKey: String
    /// One shared session for every client. Creating a URLSession per request
    /// leaked connections: each session keeps its own connection pool until it
    /// is released, and SwiftData/observation churn created plenty of clients.
    static let sharedSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    /// Injectable for tests (a `MockURLProtocol` session); ordinary callers
    /// construct without this parameter and reuse the single global pool.
    var session: URLSession = OpenAIClient.sharedSession

    init(baseURL: String, apiKey: String, session: URLSession = OpenAIClient.sharedSession) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    private func endpoint(_ path: String) throws -> URL {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { throw AIError.badURL(baseURL) }
        // Tolerate users pasting a full completions URL.
        if trimmed.hasSuffix("/chat/completions") {
            return try makeURL(trimmed)
        }
        return try makeURL(trimmed + path)
    }

    private func makeURL(_ s: String) throws -> URL {
        guard let url = URL(string: s), url.scheme != nil, url.host != nil else {
            throw AIError.badURL(s)
        }
        return url
    }

    /// One event from a streaming completion.
    enum StreamEvent {
        /// The provider answered with a 2xx and the stream is open; tokens
        /// have not started yet. This is the honest boundary between
        /// "reaching the provider" and "waiting for the model to speak".
        case connected
        /// A delta of assistant text.
        case delta(String)
        /// Provider-reported token accounting from the terminal usage chunk.
        case usage(TokenUsage)
    }

    /// Token counts as reported by the provider on the stream's final chunk.
    /// All fields optional: providers that ignore `include_usage` simply never
    /// emit this event, and "no report" must stay distinguishable from zero.
    struct TokenUsage: Equatable {
        var promptTokens: Int?
        var completionTokens: Int?
        var totalTokens: Int?
    }

    private func request(model: String, turns: [ChatTurn], temperature: Double,
                         stream: Bool) throws -> URLRequest {
        var req = URLRequest(url: try endpoint("/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any] = [
            "model": model,
            "messages": turns.map { ["role": $0.role, "content": $0.wireContent] },
            "temperature": temperature,
            "stream": stream,
        ]
        // Ask for a usage block on the final chunk when supported; harmless
        // for providers that ignore it.
        if stream { body["stream_options"] = ["include_usage": true] }

        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Streams assistant text and the terminal usage report as typed events.
    /// The sequence finishes when the server sends `[DONE]` or the connection
    /// closes.
    func stream(
        model: String,
        turns: [ChatTurn],
        temperature: Double
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let req = try request(
                        model: model, turns: turns,
                        temperature: temperature, stream: true
                    )
                    let (bytes, response) = try await session.bytes(for: req)

                    guard let http = response as? HTTPURLResponse else {
                        throw AIError.empty
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 4000 { break }
                        }
                        throw AIError.http(http.statusCode, body)
                    }
                    continuation.yield(.connected)

                    var produced = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5)
                            .trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8) else { continue }
                        if let delta = Self.deltaText(from: data), !delta.isEmpty {
                            produced = true
                            continuation.yield(.delta(delta))
                        }
                        if let usage = Self.usage(from: data) {
                            continuation.yield(.usage(usage))
                        }
                    }
                    if !produced { throw AIError.empty }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Extracts `choices[0].delta.content`, tolerating providers that instead
    /// send `choices[0].message.content` or `text`.
    private static func deltaText(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first else { return nil }
        if let delta = first["delta"] as? [String: Any],
           let s = delta["content"] as? String {
            return s
        }
        if let msg = first["message"] as? [String: Any],
           let s = msg["content"] as? String {
            return s
        }
        if let s = first["text"] as? String { return s }
        return nil
    }

    /// Extracts the terminal `usage` object from a chunk. Only present when
    /// the provider honours `include_usage`; tolerated anywhere in the stream
    /// since some providers send it early.
    private static func usage(from data: Data) -> TokenUsage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = obj["usage"] as? [String: Any] else { return nil }
        func int(_ key: String) -> Int? {
            usage[key] as? Int ?? (usage[key] as? Double).map(Int.init)
        }
        let usageKeys = ["prompt_tokens", "completion_tokens", "total_tokens"]
        guard usageKeys.contains(where: { usage[$0] != nil }) else { return nil }
        return TokenUsage(
            promptTokens: int("prompt_tokens"),
            completionTokens: int("completion_tokens"),
            totalTokens: int("total_tokens"))
    }

    /// Cheapest possible credential check: pull the model list.
    func validateConnection() async throws -> [String] {
        try await fetchModels().map(\.id)
    }

    /// Fetches the model list with capability metadata where the provider
    /// publishes it.
    ///
    /// OpenRouter is the useful case: every entry carries
    /// `architecture.input_modalities`, so image support is answered
    /// authoritatively. OpenAI/Groq/Gemini return only ids, which yield
    /// `supportsVision == nil` and defer to the name heuristic.
    func fetchModels() async throws -> [RemoteModel] {
        let url = try endpoint("/models")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw AIError.empty }
        guard (200..<300).contains(http.statusCode) else {
            throw AIError.http(
                http.statusCode,
                String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AIError.decoding("Expected a JSON object.") }

        // OpenAI-compatible shape, plus the bare-array shape some servers use.
        let raw: [[String: Any]]
        if let arr = obj["data"] as? [[String: Any]] {
            raw = arr
        } else if let arr = obj["models"] as? [[String: Any]] {
            raw = arr
        } else if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            raw = arr
        } else {
            throw AIError.decoding("No model list in the response.")
        }

        return raw.compactMap { entry -> RemoteModel? in
            guard let id = entry["id"] as? String
                    ?? entry["name"] as? String
                    ?? entry["model"] as? String
            else { return nil }
            return RemoteModel(id: id,
                               supportsVision: Self.visionFlag(from: entry))
        }
        .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    /// Reads image input support from the many shapes providers use.
    /// Returns `nil` when the provider says nothing either way.
    private static func visionFlag(from entry: [String: Any]) -> Bool? {
        // OpenRouter: architecture.input_modalities: ["text","image",...]
        if let arch = entry["architecture"] as? [String: Any] {
            if let mods = arch["input_modalities"] as? [String] {
                return mods.contains("image")
            }
            // Some deployments only expose the combined modality string,
            // e.g. "text+image+file->text".
            if let modality = arch["modality"] as? String {
                let input = modality.split(separator: ">").first.map(String.init)
                    ?? modality
                return input.contains("image")
            }
        }
        // Generic capability arrays: capabilities: ["vision", ...]
        if let caps = entry["capabilities"] as? [String] {
            return caps.contains { $0.lowercased().contains("vision")
                                 || $0.lowercased().contains("image") }
        }
        if let modalities = entry["input_modalities"] as? [String] {
            return modalities.contains("image")
        }
        // Explicit booleans some gateways add.
        if let v = entry["supports_vision"] as? Bool { return v }
        if let v = entry["vision"] as? Bool { return v }
        if let v = entry["multimodal"] as? Bool { return v }
        return nil
    }
}
