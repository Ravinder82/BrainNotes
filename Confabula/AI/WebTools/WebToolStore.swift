import Foundation
import Observation

/// A web capability provider the owner can switch on.
///
/// Two providers, two jobs: TinyFish answers "what is true right now" for free
/// (search + extraction), Monid answers "get me the actual data" for a price
/// (hundreds of pay-per-run endpoints). Everything user-facing — the settings
/// card, the probe, the prompt section — reads its copy from here.
enum WebProviderID: String, CaseIterable, Identifiable, Sendable {
    case tinyfish
    case monid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tinyfish: return "TinyFish"
        case .monid:    return "Monid"
        }
    }

    /// One line naming what the provider is for.
    var role: String {
        switch self {
        case .tinyfish: return "Web search & page extraction"
        case .monid:    return "Data endpoints on demand"
        }
    }

    /// The longer description under the card title.
    var blurb: String {
        switch self {
        case .tinyfish:
            return "Free, unlimited web search and clean page extraction. Bots use it to ground answers in current sources."
        case .monid:
            return "One key in front of hundreds of pay-per-run data endpoints for what search cannot reach — social posts, profiles, reviews, listings."
        }
    }

    var symbol: String {
        switch self {
        case .tinyfish: return "fish.fill"
        case .monid:    return "cylinder.split.1x2.fill"
        }
    }

    /// Capability chips on the settings card.
    var capabilities: [String] {
        switch self {
        case .tinyfish: return ["Search", "News", "Papers", "Extract"]
        case .monid:    return ["Discover", "Inspect", "Run"]
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .tinyfish: return "sk-tinyfish-…"
        case .monid:    return "monid_live_…"
        }
    }

    /// What a key looks like, used for a cheap sanity check before saving.
    var keyPrefix: String {
        switch self {
        case .tinyfish: return "sk-tinyfish-"
        case .monid:    return "monid_"
        }
    }

    var docsURL: URL {
        switch self {
        case .tinyfish: return URL(string: "https://docs.tinyfish.ai")!
        case .monid:    return URL(string: "https://monid.ai/docs")!
        }
    }

    /// Keychain account under the app's shared service.
    var keychainAccount: String { "webtools.\(rawValue)" }

    /// The free/paid line under the key field.
    var costNote: String {
        switch self {
        case .tinyfish: return "Search and extraction are free — they never touch a balance."
        case .monid:    return "Runs are billed from your Monid balance. Every price is shown before a bot spends."
        }
    }
}

/// The keys the owner supplied when the feature was set up.
///
/// These are seeds, not the source of truth: on first launch they are written
/// into the Keychain (under `WebProviderID.keychainAccount`) and from then on
/// the Keychain owns them — the settings screen reads and writes only there.
/// The constants below exist so the app arrives working; they are never read
/// again once `WebToolStore.seededKey` is set.
///
/// If this project is ever shared or published, clear these two constants
/// first — an API key in source is a key someone else can spend.
enum WebToolDefaults {
    static let tinyfishKey = "sk-tinyfish-Kw0D7KyCiyLQPbeE04LJ0kW3N1cmJXxz"
    static let monidKey = "monid_live_G0znNU5YpubWYnvkQ06rl11q"

    static var seedKeys: [WebProviderID: String] {
        [.tinyfish: tinyfishKey, .monid: monidKey]
    }
}

/// Where web-tool keys live.
///
/// Production uses the Keychain; tests inject an in-memory double so no test
/// can read or write a real credential. The seam exists because the store's
/// behaviour (seeding, replacing, probing) is exactly what needs testing, and
/// a test that mutates the developer's Keychain to check it is not a test.
protocol WebKeyStore: AnyObject {
    func read(_ account: String) -> String?
    func save(_ key: String, account: String) throws
    @discardableResult func delete(_ account: String) -> Bool
}

/// The real thing: the app's shared Keychain service.
final class KeychainWebKeyStore: WebKeyStore {
    func read(_ account: String) -> String? { KeychainStore.read(account: account) }

    func save(_ key: String, account: String) throws {
        try KeychainStore.save(key, account: account)
    }

    @discardableResult func delete(_ account: String) -> Bool {
        KeychainStore.delete(account: account)
    }
}

/// The owner's web-tool configuration: which providers are on, and the keys
/// behind them.
///
/// Mirrors `ProviderStore`'s discipline deliberately: `SecItemCopyMatching` is
/// a synchronous IPC round-trip to `securityd`, so view bodies never read the
/// Keychain — an in-memory mirror is the render-path source of truth and is
/// refreshed only when a key is written, removed, or probed.
@MainActor
@Observable
final class WebToolStore {
    /// The outcome of a connectivity probe, as the settings card shows it.
    enum Probe: Equatable {
        case idle
        case testing
        case passed(String)
        case failed(String)
    }

    private let defaults: UserDefaults
    private let keys: WebKeyStore
    private let enabledKey = "confabula.webtools.enabled.v1"
    private let seededKey = "confabula.webtools.seeded.v1"

    /// Providers the owner switched on. Persisted; a provider that is on but
    /// has no key is still "on" — the card shows the missing key instead of
    /// silently reverting the toggle.
    private(set) var enabledProviders: Set<WebProviderID> = []

    /// In-memory mirror of which providers have a stored key.
    private(set) var keyedProviders: Set<WebProviderID> = []

    private var cachedKeys: [WebProviderID: String] = [:]

    private(set) var probes: [WebProviderID: Probe] = [:]

    /// The last balance seen from Monid, shown on its card after a probe.
    private(set) var monidBalance: MonidBalance?

    /// Last Keychain failure, surfaced in Settings so a silent save failure is
    /// never mistaken for a successful one.
    var lastKeychainError: String?

    /// A key that looks wrong (wrong prefix) is still saved — prefixes change —
    /// but the card warns, and the probe gives the real verdict.
    var session: URLSession = OpenAIClient.sharedSession

    init(defaults: UserDefaults = .standard, keys: WebKeyStore = KeychainWebKeyStore()) {
        self.defaults = defaults
        self.keys = keys

        if let raw = defaults.array(forKey: enabledKey) as? [String] {
            enabledProviders = Set(raw.compactMap(WebProviderID.init(rawValue:)))
        } else {
            // Fresh install: both on, so the feature the owner asked for works
            // the moment the app opens.
            enabledProviders = Set(WebProviderID.allCases)
        }

        refresh()

        // UI tests need a clean Keychain so "Add key" vs "Replace" is
        // deterministic across runs — and must not be re-seeded afterwards.
        if CommandLine.arguments.contains("-reset-keys") {
            for id in WebProviderID.allCases {
                keys.delete(id.keychainAccount)
            }
            defaults.removeObject(forKey: seededKey)
            // The switches are part of the state a reset exists to make
            // deterministic: a UI run that switched a provider off must not
            // change what the next launch — or the next test — sees.
            defaults.removeObject(forKey: enabledKey)
            enabledProviders = Set(WebProviderID.allCases)
            refresh()
        } else {
            seedGivenKeys()
        }
    }

    // MARK: - Keys

    /// Whether a provider has a stored key, answered from the in-memory mirror
    /// so no Keychain round-trip happens during rendering.
    func hasKey(for id: WebProviderID) -> Bool { keyedProviders.contains(id) }

    /// The stored key. Meant for form prefills and probes, not view bodies.
    func key(for id: WebProviderID) -> String? { cachedKeys[id] }

    /// A short, non-secret rendering of the stored key: enough for the owner to
    /// recognise which key is in place, useless to anyone else.
    func maskedKey(for id: WebProviderID) -> String? {
        guard let key = cachedKeys[id], !key.isEmpty else { return nil }
        let tail = key.suffix(4)
        return "\(id.keyPrefix)…\(tail)"
    }

    func setKey(_ key: String, for id: WebProviderID) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            removeKey(for: id)
            return
        }
        do {
            try keys.save(trimmed, account: id.keychainAccount)
            lastKeychainError = nil
            cachedKeys[id] = trimmed
            keyedProviders.insert(id)
            // A new key invalidates the last probe's verdict.
            probes[id] = .idle
            if id == .monid { monidBalance = nil }
        } catch let error as KeychainError {
            lastKeychainError = error.isMissingEntitlement
                ? "The app is not signed for Keychain access. Rebuild with a "
                  + "development team so the keychain-access-groups entitlement "
                  + "is applied."
                : error.errorDescription
        } catch {
            lastKeychainError = error.localizedDescription
        }
    }

    func removeKey(for id: WebProviderID) {
        keys.delete(id.keychainAccount)
        cachedKeys[id] = nil
        keyedProviders.remove(id)
        probes[id] = .idle
        if id == .monid { monidBalance = nil }
    }

    /// Re-reads Keychain state into the mirror. Call after any external change
    /// to keys, not from a render path.
    func refresh() {
        var present: Set<WebProviderID> = []
        var found: [WebProviderID: String] = [:]
        for id in WebProviderID.allCases {
            if let key = keys.read(id.keychainAccount), !key.isEmpty {
                present.insert(id)
                found[id] = key
            }
        }
        keyedProviders = present
        cachedKeys = found
    }

    private func seedGivenKeys() {
        guard !defaults.bool(forKey: seededKey) else { return }
        for (id, key) in WebToolDefaults.seedKeys {
            if keys.read(id.keychainAccount)?.isEmpty ?? true {
                try? keys.save(key, account: id.keychainAccount)
            }
        }
        defaults.set(true, forKey: seededKey)
        refresh()
    }

    // MARK: - Enablement

    func isEnabled(_ id: WebProviderID) -> Bool { enabledProviders.contains(id) }

    func setEnabled(_ enabled: Bool, for id: WebProviderID) {
        if enabled {
            enabledProviders.insert(id)
        } else {
            enabledProviders.remove(id)
        }
        defaults.set(enabledProviders.map(\.rawValue).sorted(), forKey: enabledKey)
    }

    /// On *and* keyed: the only state in which a bot may be promised the tool.
    func isActive(_ id: WebProviderID) -> Bool {
        enabledProviders.contains(id) && hasKey(for: id)
    }

    /// Whether any provider can serve a tool call right now.
    var anyActive: Bool {
        WebProviderID.allCases.contains(where: isActive)
    }

    // MARK: - Probes

    func probe(_ id: WebProviderID) async {
        guard let key = cachedKeys[id] else {
            probes[id] = .failed("No key saved yet.")
            return
        }
        probes[id] = .testing
        let clock = ContinuousClock()
        let started = clock.now

        do {
            let verdict: String
            switch id {
            case .tinyfish:
                let client = TinyFishClient(apiKey: key, session: session)
                let hits = try await client.search(
                    query: "tinyfish api connectivity check",
                    purpose: "verifying the key works")
                verdict = hits.isEmpty
                    ? "Connected — search answered with no hits."
                    : "Connected — search returned \(hits.count) results."
            case .monid:
                let client = MonidClient(apiKey: key, session: session)
                let balance = try await client.balance()
                monidBalance = balance
                verdict = "Connected — balance \(balance.formatted)."
            }
            let ms = Int((clock.now - started) / .milliseconds(1))
            probes[id] = .passed("\(verdict) · \(ms) ms")
        } catch is CancellationError {
            probes[id] = .idle
        } catch {
            probes[id] = .failed(error.localizedDescription)
        }
    }
}