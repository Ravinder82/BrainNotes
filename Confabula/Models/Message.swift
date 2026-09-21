import Foundation
import SwiftData

enum MessageAuthor: String, Codable {
    case me
    case bot
}

enum DeliveryState: String, Codable {
    case sending
    case sent
    case delivered
    case read
    case failed
}

@Model
final class Message {
    @Attribute(.unique) var id: UUID
    var text: String
    var authorRaw: String
    var timestamp: Date
    var deliveryRaw: String
    var failureReason: String?
    var bot: Bot?

    /// Optional crew this message belongs to. Captain's crew manifests and
    /// future shared crew threads write here instead of `bot`. The two
    /// relationships are intentionally separate so a bot's own history is not
    /// polluted by the crew-level scrollback.
    var crew: Crew?

    /// Attached image bytes, kept out of the main store file. Vision-capable
    /// providers receive this as a base64 data URL alongside the text.
    @Attribute(.externalStorage) var imageData: Data?
    /// Original file name, used when exporting or sharing the attachment.
    var imageName: String?

    /// Whether this message has a photo, without touching `imageData`.
    ///
    /// `imageData` is `.externalStorage`, so merely reading it faults the blob in
    /// from disk. `hasImage` used to be derived from `imageData?.isEmpty` and is
    /// called several times per bubble per layout pass, which meant a disk read
    /// per row per frame while scrolling. This flag is a plain stored `Bool` and
    /// costs nothing to read.
    var hasImageAttachment: Bool = false

    /// Quoted-message snapshot. Stored as plain text rather than a relationship
    /// so the quote survives deletion of the original message, and so building
    /// the prompt never has to walk a message graph.
    var replyToText: String?
    var replyToAuthor: String?
    /// True when the quoted message was the user's own, for alignment/labelling.
    var replyToIsMine: Bool = false

    init(
        text: String,
        author: MessageAuthor,
        timestamp: Date = Date(),
        delivery: DeliveryState = .sending,
        failureReason: String? = nil,
        imageData: Data? = nil,
        imageName: String? = nil,
        replyToText: String? = nil,
        replyToAuthor: String? = nil,
        replyToIsMine: Bool = false
    ) {
        self.id = UUID()
        self.text = text
        self.authorRaw = author.rawValue
        self.timestamp = timestamp
        self.deliveryRaw = delivery.rawValue
        self.failureReason = failureReason
        self.imageData = imageData
        self.imageName = imageName
        self.hasImageAttachment = imageData?.isEmpty == false
        self.replyToText = replyToText
        self.replyToAuthor = replyToAuthor
        self.replyToIsMine = replyToIsMine
    }

    var hasQuote: Bool {
        replyToText?.isEmpty == false || replyToAuthor?.isEmpty == false
    }

/// One-line preview of the quoted message, trimmed for the bubble strip.
    ///
    /// Markup is stripped so a quote of a formatted reply reads as prose rather
    /// than showing raw `**` or `[]()` characters.
    ///
    /// Stripping is memoised: this is read from the bubble body (twice — once
    /// for the emptiness check and once for the value), so an uncached parse
    /// here meant markdown-parsing every quoted message on every scroll frame.
    var quotePreview: String {
        let raw = replyToText ?? ""
        let flat = MessagePreviewCache.shared.plain(from: raw)
            .replacingOccurrences(of: "\n", with: " ")
        return flat.count <= 140 ? flat : String(flat.prefix(140)) + "..."
    }

    /// True when the bubble carries a photo. Reads a stored flag, never the
    /// external-storage blob, so this is safe to call from a view body.
    var hasImage: Bool { hasImageAttachment }

    /// True when the bubble carries nothing a reader would see.
    var isEmpty: Bool { text.isEmpty && !hasImage }

    var author: MessageAuthor {
        get { MessageAuthor(rawValue: authorRaw) ?? .bot }
        set { authorRaw = newValue.rawValue }
    }

    var delivery: DeliveryState {
        get { DeliveryState(rawValue: deliveryRaw) ?? .sent }
        set { deliveryRaw = newValue.rawValue }
    }

    var isFromMe: Bool { author == .me }

    /// Timestamp as shown inside a bubble, e.g. "14:32".
    ///
    /// Backed by the shared formatter set: this is read once per visible bubble,
    /// and a freshly allocated `DateFormatter` per access was measurable.
    var timeText: String { ChatFormatters.timeString(for: timestamp) }

    /// Full date and time, used by the message-details sheet and long-press.
    var fullTimestamp: String { ChatFormatters.fullString(for: timestamp) }

    /// Date only, e.g. "14 September 2026".
    var dateText: String { ChatFormatters.dateOnlyString(for: timestamp) }
}
