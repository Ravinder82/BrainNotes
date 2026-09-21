import SwiftUI

/// One inline run of formatted content, drawn as a single `Text`.
///
/// A block's runs are concatenated into **one** attributed string rather than
/// one view per run, which is what keeps line breaking, kerning and hyphenation
/// behaving like prose: a bold phrase at the end of a line wraps as part of the
/// sentence instead of being laid out as a separate fragment.
struct MarkdownInlineText: View {
    let runs: [MDInline]
    /// Cache key for a finished message; `nil` while streaming, when the text
    /// changes on every token and caching would only thrash.
    var messageID: UUID?
    /// Distinguishes this block within its message, e.g. "p0" or "h2".
    var blockKey: String
    var font: Font
    var lineSpacing: CGFloat

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        MessageText(attributed: attributed, font: font, lineSpacing: lineSpacing)
    }

    private var attributed: AttributedString {
        guard let messageID else {
            return MessageTextBuilder.inline(runs, scheme: scheme)
        }
        return MessageTextCache.shared.inline(for: messageID,
                                              block: blockKey,
                                              runs: runs,
                                              scheme: scheme)
    }
}
