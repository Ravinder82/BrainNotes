import SwiftUI
import UIKit

/// A message body drawn as styled inline text.
///
/// `Text` — not a `UITextView` — is what keeps the bubble's layout honest: the
/// view reports the exact height its text needs at the width it is actually
/// given, so a bubble can never clip its last line or disagree with its own
/// background. Formatting is carried by the `AttributedString`, so one `Text`
/// per block preserves correct line breaking and hyphenation.
struct MessageText: View {
    let attributed: AttributedString
    var font: Font = MarkdownTheme.body
    var lineSpacing: CGFloat = MarkdownTheme.bodyLineSpacing
    var color: Color = .primary

    var body: some View {
        Text(attributed)
            .font(font)
            .foregroundStyle(color)
            .lineSpacing(lineSpacing)
    }
}

/// Builds the `AttributedString` for a message body.
///
/// Both entry points share `MessageTextCache`, so a bubble that is scrolled off
/// and back on rebuilds nothing.
enum MessageTextBuilder {

    /// Plain prose with bare URLs turned into tappable links.
    ///
    /// SwiftUI's `Text` does not linkify on its own, so URLs are detected and
    /// tagged explicitly. The detector scan is skipped entirely unless the text
    /// contains a character a link could plausibly need.
    static func linkified(_ text: String, scheme: ColorScheme) -> AttributedString {
        let source = text.isEmpty ? " " : text
        guard LinkDetector.mightContainLink(source) else {
            return AttributedString(source)
        }

        let attributed = NSMutableAttributedString(string: source)
        let linkColor = UIColor(Theme.linkText(scheme))
        let length = attributed.length
        for link in LinkDetector.links(in: source) {
            let range = link.range
            guard range.location != NSNotFound,
                  range.location + range.length <= length
            else { continue }
            attributed.addAttribute(.link, value: link.url, range: range)
            attributed.addAttribute(.foregroundColor, value: linkColor, range: range)
            attributed.addAttribute(.underlineStyle,
                                    value: NSUnderlineStyle.single.rawValue,
                                    range: range)
        }
        return AttributedString(attributed)
    }

    /// Inline runs (`**bold**`, `` `code` ``, links) as one attributed string.
    ///
    /// Terminal styles — code and links — carry their own colour, because they
    /// are drawn inside both the light and the dark bubble and must not depend
    /// on the ambient foreground style.
    static func inline(_ runs: [MDInline], scheme: ColorScheme) -> AttributedString {
        var output = AttributedString()
        for run in runs {
            switch run {
            case .text(let string):
                output.append(AttributedString(string))

            case .bold(let string):
                output.append(styled(string, font: MarkdownTheme.bodyBold))

            case .italic(let string):
                output.append(styled(string, font: MarkdownTheme.bodyItalic))

            case .boldItalic(let string):
                output.append(styled(string, font: MarkdownTheme.bodyBoldItalic))

            case .code(let string):
                var span = AttributedString(string)
                span.font = MarkdownTheme.inlineCode
                span.backgroundColor = MarkdownTheme.inlineCodeBackground(scheme)
                output.append(span)

            case .strike(let string):
                var span = AttributedString(string)
                span.strikethroughStyle = .single
                span.foregroundColor = Theme.mutedText(scheme)
                output.append(span)

            case .link(let text, let urlString):
                var span = AttributedString(text)
                if let url = URL(string: urlString) { span.link = url }
                span.foregroundColor = Theme.linkText(scheme)
                span.underlineStyle = .single
                output.append(span)
            }
        }
        return output
    }

    private static func styled(_ string: String, font: Font) -> AttributedString {
        var span = AttributedString(string)
        span.font = font
        return span
    }
}

/// Memoises built bodies.
///
/// Keyed by message, block and the text's own hash plus the colour scheme: two
/// different bodies can never share an entry, and the same body renders
/// correctly in both modes. Rebuilding these on every layout pass was the single
/// most expensive thing the bubble did.
@MainActor
final class MessageTextCache {
    static let shared = MessageTextCache()

    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 800
        return cache
    }()

    private final class Box {
        let value: AttributedString?
        /// Full-message selectable document (`MessageDocumentBuilder` output).
        let document: NSAttributedString?
        init(_ value: AttributedString) {
            self.value = value
            self.document = nil
        }
        init(document: NSAttributedString) {
            self.value = nil
            self.document = document
        }
    }

    /// Plain body for a finished message.
    func plain(for id: UUID, text: String, scheme: ColorScheme) -> AttributedString {
        let mode = scheme == .dark ? "d" : "l"
        let key = "\(id.uuidString)|plain|\(mode)|\(text.hashValue)" as NSString
        if let hit = cache.object(forKey: key), let value = hit.value { return value }
        let built = MessageTextBuilder.linkified(text, scheme: scheme)
        cache.setObject(Box(built), forKey: key)
        return built
    }

    /// One inline block of a formatted message.
    func inline(for id: UUID,
                block: String,
                runs: [MDInline],
                scheme: ColorScheme) -> AttributedString {
        let plain = MDInline.plainText(runs)
        let mode = scheme == .dark ? "d" : "l"
        let key = "\(id.uuidString)|\(block)|\(plain.hashValue)|\(mode)" as NSString
        if let hit = cache.object(forKey: key), let value = hit.value { return value }
        let built = MessageTextBuilder.inline(runs, scheme: scheme)
        cache.setObject(Box(built), forKey: key)
        return built
    }

    /// The full selectable document for a finished message, memoised per
    /// message and colour scheme.
    func document(for id: UUID,
                  source: String,
                  analysis: MessageContent.Analysis,
                  scheme: ColorScheme) -> NSAttributedString {
        let key = "\(id.uuidString)|doc|\(scheme == .dark ? "d" : "l")|\(source)" as NSString
        if let hit = cache.object(forKey: key), let document = hit.document {
            return document
        }
        let built = MessageDocumentBuilder.build(analysis: analysis, scheme: scheme)
        cache.setObject(Box(document: built), forKey: key)
        return built
    }

    func clear() { cache.removeAllObjects() }
}

/// Finds URLs in plain text, using the system data detector so it understands
/// bare domains ("example.com"), full URLs and email addresses.
enum LinkDetector {
    struct Link {
        let url: URL
        let range: NSRange
    }

    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    static func links(in text: String) -> [Link] {
        guard let detector, !text.isEmpty else { return [] }
        let full = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, options: [], range: full).compactMap { match in
            guard let url = match.url else { return nil }
            return Link(url: url, range: match.range)
        }
    }

    /// Cheap pre-check used to skip `NSDataDetector` entirely.
    ///
    /// The scan is the expensive part and almost every chat message has no link.
    /// Requiring at least one plausible marker first removes that cost from
    /// nearly every bubble: a false positive only costs the scan we would have
    /// run anyway, and a false negative is impossible for a real URL, since all
    /// of them contain a dot or a scheme separator.
    static func mightContainLink(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar {
            case ".", "@", ":": return true
            default: continue
            }
        }
        return false
    }
}
