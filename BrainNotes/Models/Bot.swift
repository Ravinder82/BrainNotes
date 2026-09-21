import Foundation
import SwiftData

/// A bot that behaves like a contact in the chat list. The user creates and
/// deletes these; each one owns a single private thread and a persona.
@Model
final class Bot {
    @Attribute(.unique) var id: UUID
    var name: String
    var avatarEmoji: String
    var avatarColorHex: String
    var persona: String
    var greeting: String
    var model: String
    var temperature: Double

    // Defaults allow lightweight migration of stores created before these fields.
    var role: String = ""
    var negativeRules: String = ""
    var systemPersonality: String = ""
    var goldenExamples: String = ""
    var agePerspective: Int = 33
    var creativity: Double = 0.7
    var configurationVersion: Int = 0

    var createdAt: Date
    var lastActivityAt: Date
    var isPinned: Bool
    var isMuted: Bool
    var unreadCount: Int
    // Defaulted so stores created before this field migrate without a rebuild.
    var isCaptainManaged: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \Message.bot)
    var messages: [Message]

    /// Crews this specialist belongs to. Captain's primary unit of work is the
    /// crew, not the individual bot, so a bot's "home" surface is the crew it
    /// sits on. Many-to-many: a research bot may serve both a Content Squad and
    /// a Strategy Crew without losing its persona or history.
    /// The inverse is declared on `Crew.members`; declaring it on both sides of
    /// a many-to-many pair makes the macro recurse.
    var crews: [Crew] = []

    init(
        name: String,
        avatarEmoji: String = "🤖",
        avatarColorHex: String = Theme.defaultAvatarHexes[0],
        persona: String = "",
        greeting: String = "",
        model: String = "",
        temperature: Double = 0.7,
        role: String = "",
        negativeRules: String = "",
        systemPersonality: String = "",
        goldenExamples: String = "",
        agePerspective: Int = Bot.defaultAgePerspective,
        creativity: Double? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.avatarEmoji = avatarEmoji
        self.avatarColorHex = avatarColorHex
        self.persona = persona
        self.greeting = greeting
        self.model = model
        self.temperature = temperature
        self.role = role
        self.negativeRules = negativeRules
        self.systemPersonality = systemPersonality.isEmpty ? persona : systemPersonality
        self.goldenExamples = goldenExamples
        self.agePerspective = max(12, min(50, agePerspective))
        let sampling = creativity ?? temperature
        self.creativity = sampling.isFinite ? max(0, min(1, sampling)) : 0.7
        self.configurationVersion = 1
        self.createdAt = Date()
        self.lastActivityAt = Date()
        self.isPinned = false
        self.isMuted = false
        self.unreadCount = 0
        self.messages = []
        self.crews = []
    }

    static let defaultAgePerspective = 33

    func migrateConfigurationIfNeeded() {
        guard configurationVersion == 0 else { return }
        systemPersonality = persona
        creativity = temperature.isFinite ? max(0, min(1, temperature)) : 0.7
        configurationVersion = 1
    }

    /// Most recent message, used for the chat-list preview row.
    ///
    /// Backed by the memoised ordering rather than a fresh scan: this runs once
    /// per visible chat-list row per layout pass, and scanning the whole
    /// relationship each time made list scrolling scale with thread length.
    var lastMessage: Message? {
        sortedMessages.last
    }

    /// Messages in chronological order.
    ///
    /// This previously sorted on every access. Callers read it many times per
    /// layout pass (once for the count, then per row for grouping and date
    /// separators), so a single scroll frame could sort the entire thread
    /// dozens of times and allocate a fresh array each time.
    ///
    /// The memo lives in `BotOrderCache`, keyed by bot id — deliberately *not* a
    /// stored property on the model. Writing a cache back onto the model from
    /// this getter mutated observed state during SwiftUI body evaluation, which
    /// re-invalidated the very view that asked for the value.
    var sortedMessages: [Message] {
        let stamp = orderStamp
        if let cached = BotOrderCache.shared.order(for: id), cached.stamp == stamp {
            return cached.list
        }
        let list = messages.sorted { $0.timestamp < $1.timestamp }
        BotOrderCache.shared.setOrder(CachedOrder(stamp: stamp, list: list), for: id)
        return list
    }

    /// Cheap O(n) fingerprint of the relationship's current membership.
    ///
    /// Count plus newest timestamp alone missed a delete-and-insert with an
    /// unchanged count and newest stamp, which would serve an array still
    /// holding a deleted `Message`. Mixing in a rolling hash of the ids detects
    /// any membership change at the same O(n) cost the newest-timestamp scan
    /// already paid.
    private var orderStamp: OrderStamp {
        var newest = Date.distantPast
        var fingerprint: UInt64 = 0
        for m in messages {
            if m.timestamp > newest { newest = m.timestamp }
            let u = m.id.uuid
            let mixed = UInt64(u.0) &* 31 &+ UInt64(u.1) &* 131
                &+ UInt64(u.2) &* 8191 &+ UInt64(u.3)
                &+ UInt64(u.4) &* 131071 &+ UInt64(u.5)
                &+ UInt64(u.6) &* 524287 &+ UInt64(u.7) &* 6700417
                &+ UInt64(u.8) &* 2147483647 &+ UInt64(u.9)
                &+ UInt64(u.10) &* 1000003 &+ UInt64(u.11)
                &+ UInt64(u.12) &* 999983 &+ UInt64(u.13)
                &+ UInt64(u.14) &* 999979 &+ UInt64(u.15)
            // Order-independent so an equal-membership reshuffle still matches.
            fingerprint ^= mixed
        }
        return OrderStamp(count: messages.count,
                          newest: newest,
                          fingerprint: fingerprint)
    }

    /// Invalidated by anything that mutates this thread's messages, so a stale
    /// ordering can never be served after a delete or a clear.
    func invalidateOrderCache() {
        BotOrderCache.shared.invalidate(id)
    }

    struct OrderStamp: Equatable {
        let count: Int
        let newest: Date
        let fingerprint: UInt64
    }

    struct CachedOrder {
        let stamp: OrderStamp
        let list: [Message]
    }
}

/// Off-model memo for `Bot.sortedMessages`.
///
/// Held outside the SwiftData model on purpose: a cache written back onto an
/// observed model from a getter invalidates the view that read it, and marks the
/// object dirty for autosave from a render path.
///
/// Lock-protected rather than `@MainActor`, because `Bot.sortedMessages` is a
/// non-isolated computed property and cannot await actor hops.
final class BotOrderCache: @unchecked Sendable {
    static let shared = BotOrderCache()

    private let lock = NSLock()
    private var orders: [UUID: Bot.CachedOrder] = [:]

    func order(for id: UUID) -> Bot.CachedOrder? {
        lock.lock()
        defer { lock.unlock() }
        return orders[id]
    }

    func setOrder(_ order: Bot.CachedOrder, for id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        // A render-path cache must not grow without bound as bots come and go.
        if orders.count > 200 { orders.removeAll(keepingCapacity: true) }
        orders[id] = order
    }

    func invalidate(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        orders[id] = nil
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        orders.removeAll()
    }
}
