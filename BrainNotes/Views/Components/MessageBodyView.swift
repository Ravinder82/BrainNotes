import SwiftUI

/// The readable part of a message: prose, or parsed markdown.
///
/// This is the branch point between the two rendering tiers. Plain prose — the
/// overwhelming majority of messages — becomes a single `Text` with linkified
/// URLs and no parser involvement at all. Formatted content is drawn block by
/// block, which is what gives lists, code and rules real layout.
///
/// Nothing here measures text or feeds layout back into layout: the body view
/// reports the height it needs for the width it is given, so a bubble can never
/// clip its last line.
struct MessageBodyView: View {
    let analysis: MessageContent.Analysis
    /// `nil` while streaming, when the body changes on every token.
    var messageID: UUID?

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch analysis {
        case .plain(let text):
            MessageText(attributed: attributed(text),
                        color: Theme.bubbleText(scheme))

        case .rich(let blocks):
            MarkdownContentView(blocks: blocks, messageID: messageID)
        }
    }

    private func attributed(_ text: String) -> AttributedString {
        guard let messageID else {
            return MessageTextBuilder.linkified(text, scheme: scheme)
        }
        return MessageTextCache.shared.plain(for: messageID, text: text, scheme: scheme)
    }
}
