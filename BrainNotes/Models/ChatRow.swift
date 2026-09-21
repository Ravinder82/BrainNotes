import Foundation

/// Everything a chat row needs to draw, computed **once** per message-set
/// change instead of during layout.
///
/// Previously the view recomputed ordering, tail flags, date separators and
/// timestamp strings inside the body, which ran on every scroll frame and
/// re-sorted the whole thread many times per pass. All of it is derived here
/// in a single pass and handed to the view as plain values.
struct ChatRow: Identifiable, Equatable {
    let id: UUID
    /// The backing model. Read only on the main actor inside the view body.
    let message: Message

    /// Draw the bubble tail (last message of a same-sender run).
    let showTail: Bool
    /// Show a date pill above this row (first message of a new day).
    let showsDateSeparator: Bool
    let dateSeparatorText: String
    /// Preformatted "HH:mm", so no DateFormatter runs during layout.
    let timeText: String
    /// Only the newest bot reply can be regenerated.
    let canRegenerate: Bool

    /// Plain values captured at build time so equality never touches the
    /// main-actor-isolated `Message` model.
    private let textLength: Int
    private let delivery: String

    init(message: Message, showTail: Bool, showsDateSeparator: Bool,
         dateSeparatorText: String, timeText: String, canRegenerate: Bool) {
        self.id = message.id
        self.message = message
        self.showTail = showTail
        self.showsDateSeparator = showsDateSeparator
        self.dateSeparatorText = dateSeparatorText
        self.timeText = timeText
        self.canRegenerate = canRegenerate
        self.textLength = message.text.count
        self.delivery = message.deliveryRaw
    }

    /// A `Sendable` snapshot of everything equality depends on.
    ///
    /// `ChatRow` itself cannot be `Sendable` (it holds a `Message`), and a view
    /// whose conformance makes it `@MainActor` cannot expose a non-`Sendable`
    /// stored property to a `nonisolated` comparison. Views therefore keep this
    /// snapshot alongside the row and compare that, off the main actor.
    struct Key: Equatable, Sendable {
        let id: UUID
        let showTail: Bool
        let showsDateSeparator: Bool
        let dateSeparatorText: String
        let timeText: String
        let canRegenerate: Bool
        let textLength: Int
        let delivery: String
    }

    var key: Key {
        Key(id: id, showTail: showTail,
            showsDateSeparator: showsDateSeparator,
            dateSeparatorText: dateSeparatorText, timeText: timeText,
            canRegenerate: canRegenerate, textLength: textLength,
            delivery: delivery)
    }

    nonisolated static func == (lhs: ChatRow, rhs: ChatRow) -> Bool {
        lhs.key == rhs.key
    }
}

/// Builds the row list in one pass.
///
/// Kept as a free function over a sorted array so it is testable without a
/// SwiftData context and cheap enough to call only when the thread changes.
enum ChatRowBuilder {
    /// Same-sender messages within this window share a visual group.
    private static let groupWindow: TimeInterval = 5 * 60

    static func build(from messages: [Message], isStreaming: Bool) -> [ChatRow] {
        guard !messages.isEmpty else { return [] }

        var rows: [ChatRow] = []
        rows.reserveCapacity(messages.count)

        // Resolved once, not per row.
        let calendar = ChatCalendar.shared
        let lastIndex = messages.count - 1

        for (index, message) in messages.enumerated() {
            let previous = index > 0 ? messages[index - 1] : nil
            let next = index < lastIndex ? messages[index + 1] : nil

            let showsSeparator: Bool
            if let previous {
                showsSeparator = !calendar.isDate(message.timestamp,
                                                   inSameDayAs: previous.timestamp)
            } else {
                showsSeparator = true
            }

            let showTail: Bool
            if let next {
                showTail = message.author != next.author
                    || next.timestamp.timeIntervalSince(message.timestamp) > groupWindow
            } else {
                showTail = true
            }

            rows.append(ChatRow(
                message: message,
                showTail: showTail,
                showsDateSeparator: showsSeparator,
                dateSeparatorText: ChatFormatters.dayString(for: message.timestamp),
                timeText: ChatFormatters.timeString(for: message.timestamp),
                canRegenerate: !message.isFromMe
                    && index == lastIndex
                    && !isStreaming
            ))
        }
        return rows
    }
}

/// One shared `Calendar`. `Calendar.current` re-resolves locale, time zone and
/// identifier on each access, and the old code called it per row per frame.
enum ChatCalendar {
    static let shared: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = .autoupdatingCurrent
        c.timeZone = .autoupdatingCurrent
        return c
    }()
}

/// Shared, preconfigured formatters. `DateFormatter` creation is expensive and
/// the previous per-access creation showed up in the row hot path.
enum ChatFormatters {
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = .autoupdatingCurrent
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.locale = .autoupdatingCurrent
        return f
    }()

    private static let full: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .medium
        f.locale = .autoupdatingCurrent
        return f
    }()

    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        f.locale = .autoupdatingCurrent
        return f
    }()

    static func timeString(for date: Date) -> String { time.string(from: date) }
    static func dayString(for date: Date) -> String { day.string(from: date) }
    static func fullString(for date: Date) -> String { full.string(from: date) }
    static func dateOnlyString(for date: Date) -> String { dateOnly.string(from: date) }
}