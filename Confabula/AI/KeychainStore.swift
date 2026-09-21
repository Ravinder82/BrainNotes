import Foundation
import Security

/// BYOK credential storage. Keys live in the Keychain (never UserDefaults),
/// scoped per provider id so multiple endpoints can coexist.
struct ProviderConfig: Codable, Equatable, Identifiable {
    var id: UUID
    /// Human label shown in Settings, e.g. "OpenRouter".
    var label: String
    /// OpenAI-compatible base URL, e.g. https://api.openai.com/v1
    var baseURL: String
    var defaultModel: String
    var isActive: Bool

    static func openAI() -> ProviderConfig {
        ProviderConfig(
            id: UUID(),
            label: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            defaultModel: "gpt-4o-mini",
            isActive: true
        )
    }
}

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let s):
            let msg = SecCopyErrorMessageString(s, nil) as String? ?? "unknown"
            return "Keychain error \(s): \(msg)"
        }
    }

    /// -34018 shows up whenever the app is unsigned or missing the
    /// keychain-access-groups entitlement, which is the usual reason a BYOK
    /// key appears to save but never persists.
    var isMissingEntitlement: Bool {
        if case .unexpectedStatus(let s) = self { return s == -34018 }
        return false
    }
}

/// Thin wrapper over the Security framework for API keys.
enum KeychainStore {
    private static let service = "com.confabula.apikeys"

    static func save(_ key: String, account: String) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Update in place when the item already exists. The old delete-then-add
        // dance was two IPC round-trips with a window between them where a crash
        // or the delete returning errSecItemNotFound would drop the user's key.
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8),
              !str.isEmpty
        else { return nil }
        return str
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}

/// Non-secret provider metadata (base URL, chosen model). Stored in
/// UserDefaults; the API key itself never is.
@MainActor
@Observable
final class ProviderStore {
    private let defaultsKey = "confabula.providers.v1"
    private let activeKey = "confabula.activeProviderID"

    var providers: [ProviderConfig] = []
    var activeProviderID: UUID?

    /// Last keychain failure, surfaced in Settings so a silent save failure is
    /// never mistaken for a successful one.
    var lastKeychainError: String?

    /// Shared model-capability cache. Lives here so the settings screen and the
    /// chat screen resolve image support from the same data.
    let catalog = ModelCatalog()

    /// In-memory mirror of which providers have a stored key.
    ///
    /// `SecItemCopyMatching` is a synchronous IPC round-trip to `securityd`, and
    /// the settings cards used to call it from inside a view body — so it ran on
    /// every layout pass. This set is the render-path source of truth and is
    /// refreshed only when a key is actually written or removed.
    private(set) var providersWithStoredKey: Set<UUID> = []

    /// The active provider's key, read once and kept in memory.
    ///
    /// Never read the Keychain from a view body; call `refreshKeyCache()` when
    /// the underlying state may have changed externally.
    private var cachedActiveKey: String?

    var active: ProviderConfig? {
        providers.first { $0.id == activeProviderID }
            ?? providers.first { $0.isActive }
            ?? providers.first
    }

    var activeAPIKey: String? { cachedActiveKey }

    var isConfigured: Bool {
        guard let p = active, !p.baseURL.isEmpty, !p.defaultModel.isEmpty else {
            return false
        }
        return (cachedActiveKey?.isEmpty == false)
    }

    /// Re-reads keychain state into memory. Call after any change to keys or the
    /// active provider, not from a render path.
    func refreshKeyCache() {
        var present: Set<UUID> = []
        for p in providers {
            if let key = KeychainStore.read(account: p.id.uuidString),
               !key.isEmpty {
                present.insert(p.id)
            }
        }
        providersWithStoredKey = present
        if let id = active?.id {
            cachedActiveKey = KeychainStore.read(account: id.uuidString)
        } else {
            cachedActiveKey = nil
        }
    }

    init() {
        load()
        // UI tests need a clean Keychain so assertions about "Add key" vs
        // "Replace key" are deterministic across runs.
        if CommandLine.arguments.contains("-reset-keys") {
            for p in providers {
                KeychainStore.delete(account: p.id.uuidString)
            }
        }
        refreshKeyCache()
    }

    func load() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([ProviderConfig].self, from: data) {
            providers = decoded
        }
        if providers.isEmpty {
            providers = [ProviderConfig.openAI()]
            persist()
        }
        if let raw = UserDefaults.standard.string(forKey: activeKey),
           let id = UUID(uuidString: raw) {
            activeProviderID = id
        }
        activeProviderID = activeProviderID ?? providers.first?.id
    }

    func persist() {
        if let data = try? JSONEncoder().encode(providers) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        if let id = activeProviderID {
            UserDefaults.standard.set(id.uuidString, forKey: activeKey)
        }
    }

    /// Whether a provider has a stored key, answered from the in-memory mirror so
/// no Keychain round-trip happens during rendering.
    func hasKey(for providerID: UUID) -> Bool {
        providersWithStoredKey.contains(providerID)
    }

    /// Reads a key's value. Prefer `hasKey(for:)` in view bodies; this performs
    /// an IPC round-trip and is meant for form prefills and connection tests.
    func apiKey(for providerID: UUID) -> String? {
        KeychainStore.read(account: providerID.uuidString)
    }

    func setAPIKey(_ key: String, for providerID: UUID) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.delete(account: providerID.uuidString)
            lastKeychainError = nil
            providersWithStoredKey.remove(providerID)
            if active?.id == providerID { cachedActiveKey = nil }
            return
        }
        do {
            try KeychainStore.save(trimmed, account: providerID.uuidString)
            lastKeychainError = nil
            providersWithStoredKey.insert(providerID)
            if active?.id == providerID { cachedActiveKey = trimmed }
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

    func upsert(_ config: ProviderConfig) {
        if let idx = providers.firstIndex(where: { $0.id == config.id }) {
            providers[idx] = config
        } else {
            providers.append(config)
        }
        persist()
    }

    func remove(_ providerID: UUID) {
        KeychainStore.delete(account: providerID.uuidString)
        providersWithStoredKey.remove(providerID)
        providers.removeAll { $0.id == providerID }
        if activeProviderID == providerID {
            activeProviderID = providers.first?.id
        }
        if providers.isEmpty {
            providers = [ProviderConfig.openAI()]
            activeProviderID = providers.first?.id
        }
        persist()
        refreshKeyCache()
    }

    func setActive(_ providerID: UUID) {
        activeProviderID = providerID
        for i in providers.indices {
            providers[i].isActive = providers[i].id == providerID
        }
        persist()
        // The active key follows the active provider.
        cachedActiveKey = KeychainStore.read(account: providerID.uuidString)
    }
}
