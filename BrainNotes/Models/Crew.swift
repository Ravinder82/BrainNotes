import Foundation
import SwiftData

/// A crew is a small team of specialist bots that work a single outcome
/// together — Captain's primary unit of delegation.
///
/// Captain no longer creates lone specialists; he assembles crews (the
/// WhatsApp-group model). Each crew owns a name, a mission, a visual identity
/// and an ordered roster. The same bot may belong to several crews, so the
/// many-to-many edge on `Bot.crews` is the source of truth.
@Model
final class Crew {
    @Attribute(.unique) var id: UUID
    /// Display name shown on the card and as the chat-list row title. Trimmed
    /// at validation; a blank name fails the action.
    var name: String
    /// One-line mission — what this crew owns. Appears under the name and is
    /// also the surface a Captain reply quotes when explaining why the crew
    /// was assembled.
    var mission: String
    /// Emoji used as the crew's avatar glyph. Defaults to "🎯" so an
    /// under-specified action still produces a recognisable icon.
    var emoji: String
    /// Tint for the avatar disc and accent borders. Hex string so SwiftData
    /// can store it without a value transformer.
    var accentColorHex: String

    /// Captain who assembled this crew. `nil` if a future user-created crew
    /// ever exists; today every crew is Captain-managed.
    var assembledByID: UUID?

    var createdAt: Date
    /// Latest activity anywhere on this crew (last reply, last message, last
    /// member edit). Updated by the chat engine and by the crew actions.
    var lastActivityAt: Date

    /// Chat-list ordering signals, identical in spirit to `Bot`'s.
    var isPinned: Bool
    var isMuted: Bool
    var unreadCount: Int

    /// Order index used to preserve the roster layout the action emitted. Lower
    /// numbers render first on the card's avatar stack. Defaults to 0; the
    /// action processor writes the index alongside the relationship so the UI
    /// never has to sort by insertion time (which can drift with model
    /// materialisation order).
    var sortIndex: Int

    /// Comma-separated UUID strings, preserving the order Captain emitted the
    /// specialists in. Simpler than a transformable for SwiftData and gives us
    /// the card's avatar stack order without relying on insertion order.
    var memberIDsString: String

    @Relationship(deleteRule: .nullify, inverse: \Bot.crews)
    var members: [Bot]

    @Relationship(deleteRule: .cascade, inverse: \Message.crew)
    var messages: [Message]

    init(
        name: String,
        mission: String,
        emoji: String = "🎯",
        accentColorHex: String = "00A884",
        members: [Bot] = [],
        assembledByID: UUID? = nil,
        sortIndex: Int = 0
    ) {
        self.id = UUID()
        self.name = name
        self.mission = mission
        self.emoji = emoji
        self.accentColorHex = accentColorHex
        self.members = members
        self.memberIDsString = members.map { $0.id.uuidString }.joined(separator: ",")
        self.assembledByID = assembledByID
        self.createdAt = Date()
        self.lastActivityAt = Date()
        self.isPinned = false
        self.isMuted = false
        self.unreadCount = 0
        self.sortIndex = sortIndex
        self.messages = []
    }

    /// Members in the order Captain emitted them. Empty UUIDs (a deleted
    /// member whose ID lingers in the ordering string) are filtered so the
    /// stack never shows a phantom.
    var orderedMembers: [Bot] {
        let byID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        let preferred = memberIDsString.split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) }
        var seen = Set<UUID>()
        var result: [Bot] = []
        for id in preferred {
            if seen.insert(id).inserted, let bot = byID[id] {
                result.append(bot)
            }
        }
        // Any member that exists in the relationship but is missing from the
        // stored order still needs to show, after the explicit ones.
        for bot in members where !seen.contains(bot.id) {
            result.append(bot)
            seen.insert(bot.id)
        }
        return result
    }

    /// Most recent message, used by the chat-list preview row.
    var lastMessage: Message? {
        sortedMessages.last
    }

    /// Messages in chronological order. Cached identically to `Bot.sortedMessages`
    /// to keep the same memoisation discipline — a crew thread scanned dozens of
    /// times per layout pass would otherwise sort on every read.
    var sortedMessages: [Message] {
        let stamp = orderStamp
        if let cached = CrewOrderCache.shared.order(for: id), cached.stamp == stamp {
            return cached.list
        }
        let list = messages.sorted { $0.timestamp < $1.timestamp }
        CrewOrderCache.shared.setOrder(CachedOrder(stamp: stamp, list: list), for: id)
        return list
    }

    func invalidateOrderCache() {
        CrewOrderCache.shared.invalidate(id)
    }

    private var orderStamp: OrderStamp {
        var newest = Date.distantPast
        var fingerprint: UInt64 = 0
        for m in messages {
            if m.timestamp > newest { newest = m.timestamp }
            fingerprint ^= Crew.fingerprint(for: m.id)
        }
        return OrderStamp(count: messages.count, newest: newest, fingerprint: fingerprint)
    }

    private static func fingerprint(for uuid: UUID) -> UInt64 {
        let u = uuid.uuid
        let bytes = withUnsafeBytes(of: u) { Array($0) }
        var h: UInt64 = 1469598103934665603
        for byte in bytes {
            h ^= UInt64(byte)
            h &*= 1099511628211
        }
        return h
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

/// Off-model memo for `Crew.sortedMessages` — same discipline as
/// `BotOrderCache`: a cache written back onto an observed SwiftData model
/// during a view body invalidates the view that read it.
final class CrewOrderCache: @unchecked Sendable {
    static let shared = CrewOrderCache()

    private let lock = NSLock()
    private var orders: [UUID: Crew.CachedOrder] = [:]

    func order(for id: UUID) -> Crew.CachedOrder? {
        lock.lock()
        defer { lock.unlock() }
        return orders[id]
    }

    func setOrder(_ order: Crew.CachedOrder, for id: UUID) {
        lock.lock()
        defer { lock.unlock() }
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