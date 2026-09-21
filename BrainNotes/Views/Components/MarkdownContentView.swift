import SwiftUI

/// Draws parsed markdown blocks inside a bubble.
///
/// Blocks become separate views because `Text` cannot express hanging-indented
/// lists, tinted code surfaces, quote bars or rules. Inline runs stay a single
/// `Text` per block, which preserves correct line breaking.
///
/// The stack is `leading`-aligned and hugs its content, so a two-word reply
/// produces a two-word-wide bubble rather than a full-width one.
struct MarkdownContentView: View {
    let blocks: [MDBlock]
    /// Cache key for a finished message; `nil` while streaming.
    var messageID: UUID?

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: MarkdownTheme.paragraphSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownBlockView(block: block,
                                  messageID: messageID,
                                  isFirst: index == 0)
                    .padding(.top, topPadding(for: block, isFirst: index == 0))
            }
        }
        // No `frame(maxWidth:)` here: the bubble's layout measures this stack to
        // find its natural width, and a flexible frame would report the whole
        // available width instead, which is how a short reply ends up in a
        // full-width bubble.
    }

    /// Headings get extra air above; every other block relies on the stack
    /// spacing, so the gap after a paragraph stays even.
    private func topPadding(for block: MDBlock, isFirst: Bool) -> CGFloat {
        guard !isFirst, case .heading(let level, _) = block else { return 0 }
        return max(0, MarkdownTheme.headingTopPadding(level) - MarkdownTheme.paragraphSpacing)
    }
}

/// Renders one block. Kept separate from the stack above so the padding rule and
/// the block switch do not have to share a body.
private struct MarkdownBlockView: View {
    let block: MDBlock
    var messageID: UUID?
    var isFirst: Bool

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch block {
        case .paragraph(let runs):
            MarkdownInlineText(runs: runs,
                               messageID: messageID,
                               blockKey: "p",
                               font: MarkdownTheme.body,
                               lineSpacing: MarkdownTheme.bodyLineSpacing)

        case .heading(let level, let runs):
            VStack(alignment: .leading, spacing: MarkdownTheme.headingBottomPadding) {
                MarkdownInlineText(runs: runs,
                                   messageID: messageID,
                                   blockKey: "h\(level)",
                                   font: MarkdownTheme.heading(level),
                                   lineSpacing: 2)
                if MarkdownTheme.headingRuleVisible(level) {
                    Rectangle()
                        .fill(MarkdownTheme.ruleColor(scheme))
                        .frame(height: MarkdownTheme.ruleThickness)
                }
            }

        case .bulletList(let items):
            MarkdownListView(items: items,
                             markers: Array(repeating: "•", count: items.count),
                             messageID: messageID)

        case .numberedList(let start, let items):
            MarkdownListView(items: items,
                             markers: items.indices.map { "\(start + $0)." },
                             messageID: messageID)

        case .codeBlock(let language, let code):
            MarkdownCodeBlockView(code: code, language: language)

        case .quote(let inner):
            MarkdownQuoteView(blocks: inner, messageID: messageID)

        case .rule:
            Rectangle()
                .fill(MarkdownTheme.ruleColor(scheme))
                .frame(height: MarkdownTheme.ruleThickness)
                .padding(.vertical, MarkdownTheme.ruleVerticalPadding)
        }
    }
}

/// A bullet or numbered list.
///
/// The marker sits in a fixed-width column so "•" and "10." line up, and the
/// item's content hangs beside it — wrapped lines align under the text, not
/// under the marker, which is the whole reason lists need real layout.
private struct MarkdownListView: View {
    let items: [MDListItem]
    let markers: [String]
    var messageID: UUID?

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: MarkdownTheme.listItemSpacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top,
                       spacing: MarkdownTheme.listMarkerGap) {
                    Text(markers.indices.contains(index) ? markers[index] : "•")
                        .font(MarkdownTheme.body.monospacedDigit())
                        .foregroundStyle(MarkdownTheme.listMarkerColor(scheme))
                        .frame(width: MarkdownTheme.listMarkerColumnWidth,
                               alignment: .trailing)
                    NestedBlocksView(blocks: item.blocks, messageID: messageID)
                }
            }
        }
    }
}

/// A blockquote: accent bar with the quoted content inset beside it.
private struct MarkdownQuoteView: View {
    let blocks: [MDBlock]
    var messageID: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Capsule()
                .fill(Theme.accent)
                .frame(width: MarkdownTheme.quoteBarWidth)
            NestedBlocksView(blocks: blocks, messageID: messageID)
                .foregroundStyle(.secondary)
                .padding(.leading, MarkdownTheme.quoteLeadingPadding)
        }
        .padding(.top, MarkdownTheme.quoteTopPadding)
    }
}

/// Fenced code on a recessed surface.
///
/// Horizontally scrollable so a long line is neither truncated nor allowed to
/// force the bubble wider than every other message in the thread.
private struct MarkdownCodeBlockView: View {
    let code: String
    let language: String?

    @Environment(\.colorScheme) private var scheme

    private var cornerRadius: CGFloat { MarkdownTheme.codeCornerRadius }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language, !language.isEmpty {
                Text(language.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.isEmpty ? " " : code)
                    .font(MarkdownTheme.code)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, MarkdownTheme.codePadding)
                    .padding(.vertical, MarkdownTheme.codeTopPadding)
            }
            .background(MarkdownTheme.codeBackground(scheme), in: shape)
            .overlay(shape.stroke(MarkdownTheme.ruleColor(scheme),
                                  lineWidth: MarkdownTheme.ruleThickness))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(code))
    }
}

/// A nested document: a list item's content, or a quote's body.
///
/// This is the one place the renderer erases its type. Recursion is inherent —
/// a list item holds blocks, a quote holds blocks — and Swift cannot infer a
/// view whose body contains itself. Erasing here costs a boxed reference per
/// nested block, of which a message has a handful, and keeps `Body` types
/// concrete everywhere else.
private struct NestedBlocksView: View {
    let blocks: [MDBlock]
    var messageID: UUID?

    var body: some View {
        AnyView(MarkdownContentView(blocks: blocks, messageID: messageID))
    }
}
