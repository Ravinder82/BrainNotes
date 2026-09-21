import SwiftUI

/// Places one bubble in a row: hugging its content up to a maximum width,
/// aligned to the sender's side, with a guaranteed gap on the far side.
///
/// This is a `Layout` rather than an `HStack` with a `Spacer` on purpose. With
/// two flexible children — a bubble that can wrap to any width, and a spacer
/// that can take any width — SwiftUI splits the leftover space between them
/// instead of giving the bubble its natural size. The visible results were a
/// short message sitting in a nearly full-width bubble, a long message wrapping
/// earlier than it needed to, and text that ended up laid out against a width it
/// was then truncated to fit.
///
/// Measuring once and clamping explicitly removes the ambiguity: the bubble is
/// exactly as wide as its content, capped by the maximum.
struct ChatBubbleLayout: Layout {
    /// Widest the bubble may be.
    let maxWidth: CGFloat
    /// Space kept clear on the opposite side, so the tail side stays obvious.
    let oppositeInset: CGFloat
    /// Whether the bubble sits on the right.
    let isOutgoing: Bool

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout Void) -> CGSize {
        let available = proposal.width ?? (maxWidth + oppositeInset)
        guard let bubble = subviews.first else { return .zero }
        let width = width(for: bubble, available: available)
        let height = bubble.sizeThatFits(
            ProposedViewSize(width: width, height: proposal.height)
        ).height
        return CGSize(width: available, height: height)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout Void) {
        guard let bubble = subviews.first else { return }
        let width = width(for: bubble, available: bounds.width)
        let size = bubble.sizeThatFits(
            ProposedViewSize(width: width, height: bounds.height)
        )
        bubble.place(
            at: CGPoint(x: isOutgoing ? bounds.maxX - size.width : bounds.minX,
                        y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: size.height)
        )
    }

    /// The bubble's natural width, clamped so the far side keeps its gap.
    private func width(for bubble: LayoutSubview, available: CGFloat) -> CGFloat {
        let limit = min(maxWidth, max(0, available - oppositeInset))
        let ideal = bubble.sizeThatFits(.unspecified).width
        return min(ideal, limit)
    }
}
