import Foundation

/// Decides how a message body should be rendered.
///
/// Two tiers, because the cost of parsing must not land on ordinary prose:
///
/// - **Plain** (the common case) skips parsing entirely and renders as a single
///   styled `Text`, exactly as the app did before markdown support.
/// - **Rich** is parsed into blocks once and cached by content hash, then drawn
///   block by block so lists, rules and code surfaces lay out properly.
enum MessageContent {

    /// Result of analysing a body.
    enum Analysis: Equatable {
        case plain(String)
        case rich([MDBlock])

        /// Flattened text, for previews, quotes and accessibility.
        var plainText: String {
            switch self {
            case .plain(let text): return text
            case .rich(let blocks): return blocks.plainText
            }
        }
    }

    static func analyse(_ text: String) -> Analysis {
        guard !text.isEmpty else { return .plain("") }
        guard MarkdownParser.containsMarkup(text) else { return .plain(text) }
        let blocks = MarkdownParser.parse(text)
        // A single plain paragraph means the markers were incidental — a
        // sentence with an asterisk, say. Fall back to the cheap path so the
        // bubble renders exactly as an unformatted one.
        if blocks.count == 1,
           case .paragraph(let runs) = blocks[0],
           runs.count == 1,
           case .text = runs[0] {
            return .plain(text)
        }
        return .rich(blocks)
    }

    /// Strips markup to readable prose, for chat-list previews and quote strips
    /// so they never display raw `**` or `[]()` characters.
    static func plainText(from text: String) -> String {
        guard !text.isEmpty else { return "" }
        guard MarkdownParser.containsMarkup(text) else { return text }
        let flattened = MarkdownParser.parse(text).plainText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.isEmpty ? text : flattened
    }
}

/// Caches analysed bodies.
///
/// Keyed on the text itself: two messages with identical bodies share an entry,
/// and a changed body can never return a stale result.
@MainActor
final class MessageContentCache {
    static let shared = MessageContentCache()

    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 400
        return cache
    }()

    private final class Box {
        let value: MessageContent.Analysis
        init(_ value: MessageContent.Analysis) { self.value = value }
    }

    func analysis(for text: String) -> MessageContent.Analysis {
        let key = "\(text.hashValue)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let analysed = MessageContent.analyse(text)
        cache.setObject(Box(analysed), forKey: key)
        return analysed
    }

    func clear() { cache.removeAllObjects() }
}

/// Caches markup-stripped previews.
///
/// `MessageContent.plainText` runs the block parser and is read from the bubble
/// (quote strips), the chat-list row and the composer's reply bar, so a
/// chat-list scroll would otherwise reparse every visible preview per frame.
///
/// Deliberately not `@MainActor`: `Message.quotePreview` is a non-isolated
/// computed property and `MarkdownParser` is pure. `NSCache` is thread-safe,
/// which the unchecked conformance records.
final class MessagePreviewCache: @unchecked Sendable {
    static let shared = MessagePreviewCache()

    private let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 300
        return cache
    }()

    func plain(from text: String) -> String {
        guard !text.isEmpty else { return "" }
        // Cheap rejection before hashing: most previews carry no markup at all.
        guard MarkdownParser.containsMarkup(text) else { return text }
        let key = "\(text.hashValue)" as NSString
        if let hit = cache.object(forKey: key) { return hit as String }
        let stripped = MessageContent.plainText(from: text)
        cache.setObject(stripped as NSString, forKey: key)
        return stripped
    }

    func clear() { cache.removeAllObjects() }
}
