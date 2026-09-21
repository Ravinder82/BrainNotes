import Foundation

/// Whether a model can accept images as input.
///
/// Three states rather than a bool: a provider may simply not tell us, and
/// "we don't know" should behave differently from "definitely no".
enum VisionSupport: Equatable {
    case supported
    case unsupported
    /// The provider exposes no capability metadata and the model name isn't
    /// recognised, so the request is allowed but may be ignored.
    case unknown

    var allowsImages: Bool { self != .unsupported }

    var shortLabel: String {
        switch self {
        case .supported:   return "Images supported"
        case .unsupported: return "Text only"
        case .unknown:     return "Image support unknown"
        }
    }
}

/// One entry from a provider's `/models` listing, reduced to what the UI needs.
struct RemoteModel: Identifiable, Equatable {
    let id: String
    /// `nil` when the provider gave no capability metadata.
    let supportsVision: Bool?

    var visionSupport: VisionSupport {
        switch supportsVision {
        case .some(true):  return .supported
        case .some(false): return .unsupported
        case .none:        return .unknown
        }
    }
}

/// Resolves which models accept image input, per provider.
///
/// OpenRouter publishes `architecture.input_modalities` for every model, which
/// is authoritative. OpenAI, Groq and Gemini expose only ids, so their answers
/// come from `VisionHeuristic` instead. Results are cached per provider + model
/// so switching bots never re-hits the network.
@MainActor
@Observable
final class ModelCatalog {
    /// provider key -> (model id -> supports vision)
    private var cache: [String: [String: Bool]] = [:]
    /// provider keys currently being fetched, so we don't fire duplicates.
    private var inFlight: Set<String> = []
    /// Last failure per provider, surfaced so a broken key is diagnosable.
    private(set) var lastError: [String: String] = [:]

    /// Models discovered for a provider, used by the model picker.
    private(set) var modelsByProvider: [String: [RemoteModel]] = [:]

    private func key(baseURL: String) -> String {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s.lowercased()
    }

    /// Resolves support for one model, consulting the cache, then the fetched
    /// catalog, then the name heuristic.
    func support(for modelID: String, provider: ProviderConfig?) -> VisionSupport {
        guard let provider, !provider.baseURL.isEmpty else { return .unsupported }
        let k = key(baseURL: provider.baseURL)
        if let known = cache[k]?[modelID] {
            return known ? .supported : .unsupported
        }
        return VisionHeuristic.support(for: modelID)
    }

    func models(for provider: ProviderConfig?) -> [RemoteModel] {
        guard let provider else { return [] }
        return modelsByProvider[key(baseURL: provider.baseURL)] ?? []
    }

    func isLoading(for provider: ProviderConfig?) -> Bool {
        guard let provider else { return false }
        return inFlight.contains(key(baseURL: provider.baseURL))
    }

    func error(for provider: ProviderConfig?) -> String? {
        guard let provider else { return nil }
        return lastError[key(baseURL: provider.baseURL)]
    }

    /// Fetches and caches the provider's model list. Safe to call repeatedly;
    /// concurrent calls for the same provider collapse into one request.
    func refresh(provider: ProviderConfig?, apiKey: String) async {
        guard let provider, !provider.baseURL.isEmpty else { return }
        let k = key(baseURL: provider.baseURL)
        guard !inFlight.contains(k) else { return }

        inFlight.insert(k)
        defer { inFlight.remove(k) }

        let client = OpenAIClient(baseURL: provider.baseURL, apiKey: apiKey)
        do {
            let fetched = try await client.fetchModels()
            guard !fetched.isEmpty else {
                lastError[k] = "The provider returned no models."
                return
            }
            modelsByProvider[k] = fetched
            var map: [String: Bool] = [:]
            for m in fetched {
                if let v = m.supportsVision { map[m.id] = v }
            }
            cache[k] = map
            lastError[k] = nil
        } catch {
            // Keep any previously cached answers; just report the failure.
            lastError[k] = error.localizedDescription
        }
    }
}

/// Name-based fallback for providers that publish no capability metadata.
///
/// Deliberately conservative: only returns `.unsupported` for families that are
/// text-only, and leaves genuinely unrecognised names as `.unknown` so a new
/// vision model isn't blocked by our ignorance.
enum VisionHeuristic {
    /// Substrings marking a known vision-capable family.
    private static let visionMarkers: [String] = [
        "gpt-4o", "gpt-4.1", "gpt-4-turbo", "gpt-4-vision", "gpt-5",
        "o3", "o4", "chatgpt-4o",
        "claude-3", "claude-4", "claude-sonnet", "claude-opus", "claude-haiku",
        "gemini", "gemma-3",
        "grok-2-vision", "grok-3", "grok-4", "grok-2-image",
        "llava", "pixtral", "internvl", "minicpm-v", "moondream",
        "qwen-vl", "qwen2-vl", "qwen2.5-vl", "qwen3-vl",
        "llama-3.2-11b", "llama-3.2-90b", "llama-4", "mllama",
        "phi-3.5-vision", "phi-4-multimodal", "glm-4v", "glm-4.1v",
        "idefics", "paligemma", "florence", "kosmos",
        "-vision", "vision-", "multimodal",
    ]

    /// Substrings marking a family that is text-only even though a sibling
    /// model in the same family takes images.
    private static let textOnlyMarkers: [String] = [
        "deepseek-chat", "deepseek-reasoner", "deepseek-coder",
        "llama-3.3", "llama-3.1", "llama-3-", "llama-2",
        "mistral-small", "mistral-medium", "mistral-large", "mixtral",
        "qwen2.5-72b", "qwen2.5-32b", "qwen2.5-14b", "qwen2.5-coder",
        "gpt-3.5", "davinci", "babbage", "curie",
        "o1-mini", "o1-preview",
        "command-r", "command-light",
        "yi-", "falcon", "mpt-", "pythia", "vicuna", "wizardlm",
        "phi-3-mini", "phi-3-small", "phi-3-medium",
        "codestral", "codellama", "starcoder", "granite",
        "hermes", "nous-", "solar-", "openchat", "zephyr",
    ]

    static func support(for modelID: String) -> VisionSupport {
        let m = modelID.lowercased()
        guard !m.isEmpty else { return .unknown }

        // Vision wins first: "llama-3.2-11b-vision" also matches "llama-3.2".
        if visionMarkers.contains(where: { m.contains($0) }) { return .supported }
        if textOnlyMarkers.contains(where: { m.contains($0) }) { return .unsupported }
        return .unknown
    }
}