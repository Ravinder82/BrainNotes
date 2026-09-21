import SwiftUI

/// A speech bubble: rounded rectangle with a pointed tail in the bottom corner
/// on the sender's side.
///
/// The tail is drawn *inside* the shape's frame rather than protruding past it.
/// A path that drew outside its own frame would be clipped by the row's
/// `.clipped()` and would not be accounted for in layout, so the whole shape is
/// built to fit the rect it is handed.
///
/// The path is written once with the tail on the right and mirrored for the
/// incoming case, so the two sides cannot drift apart.
struct BubbleShape: Shape {
    let isOutgoing: Bool
    /// Only the last message of a same-sender run carries the tail.
    let tail: Bool

    func path(in rect: CGRect) -> Path {
        let path = shapePath(in: rect)
        guard !isOutgoing else { return path }
        // Mirror horizontally about the rect's centre line.
        let mirror = CGAffineTransform(translationX: rect.minX + rect.maxX, y: 0)
            .scaledBy(x: -1, y: 1)
        return path.applying(mirror)
    }

    /// Rounded rect, tail on the right.
    private func shapePath(in rect: CGRect) -> Path {
        let radius = min(ChatLayout.bubbleCornerRadius,
                         min(rect.width, rect.height) / 2)
        let tailWidth = min(ChatLayout.tailWidth, rect.width / 3)
        let tailHeight = min(ChatLayout.tailHeight, rect.height / 3)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))

        // Top edge and top-right corner.
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                          control: CGPoint(x: rect.maxX, y: rect.minY))

        if tail {
            // Right edge stops short of the bottom and curves inward to the
            // bottom edge, cutting the corner into a tail.
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - tailHeight))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - tailWidth, y: rect.maxY),
                              control: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                              control: CGPoint(x: rect.maxX, y: rect.maxY))
        }

        // Bottom edge and bottom-left corner.
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                          control: CGPoint(x: rect.minX, y: rect.maxY))

        // Left edge and top-left corner.
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY),
                          control: CGPoint(x: rect.minX, y: rect.minY))

        path.closeSubpath()
        return path
    }
}