import CoreGraphics

/// Geometry for the chat thread, in one place.
///
/// Every magic number that used to be scattered through the bubble, the row and
/// the composer lives here, so the thread can be re-tuned without hunting for
/// constants and without two views quietly disagreeing about padding.
enum ChatLayout {

    // MARK: - Bubbles

    static let bubbleCornerRadius: CGFloat = 14
    /// Tail sits in the bottom corner on the sender's side.
    static let tailWidth: CGFloat = 8
    static let tailHeight: CGFloat = 8

    static let bubblePaddingH: CGFloat = 9
    static let bubblePaddingV: CGFloat = 6
    /// Gap between quote strip, photo, body and meta line.
    static let bubbleContentSpacing: CGFloat = 5
    /// Gap between the body and an inline timestamp on the same line.
    static let inlineMetaSpacing: CGFloat = 6

    /// Bubbles never exceed this share of the screen width…
    private static let bubbleWidthRatio: CGFloat = 0.86
    /// …nor this absolute cap, so a bubble cannot span an iPad edge to edge.
    private static let bubbleWidthCap: CGFloat = 560
    /// Minimum empty space on the far side, which keeps the tail side obvious
    /// even when a short bubble could otherwise sit dead centre.
    static let oppositeSideMinInset: CGFloat = 44

    static func maxBubbleWidth(in screenWidth: CGFloat) -> CGFloat {
        min(screenWidth * bubbleWidthRatio, bubbleWidthCap)
    }

    /// A plain message at most this long sits beside its timestamp on one line.
    ///
    /// Deliberately a length test rather than a text measurement: measuring
    /// feeds layout back into layout, which is what caused the previous
    /// implementation to clip and reflow. At body size, 30 characters plus the
    /// timestamp fits the usable bubble width on the narrowest supported phone,
    /// so the inline layout can never overflow.
    static let inlineMetaCharacterLimit = 30

    // MARK: - Thread

    static let rowSpacing: CGFloat = 3
    static let threadPaddingH: CGFloat = 8
    static let threadPaddingV: CGFloat = 8
    /// Distance from the bottom at which the thread still counts as pinned, so a
    /// small overscroll does not stop the view following a new message.
    static let pinnedThreshold: CGFloat = 80

    // MARK: - Composer

    static let composerPaddingH: CGFloat = 10
    static let composerPaddingV: CGFloat = 8
    /// Capsule at single-line height (SwiftUI clamps the radius to half the
    /// field), and a soft 22pt lozenge as the field grows to six lines.
    static let composerFieldCornerRadius: CGFloat = 22
    static let composerFieldPaddingH: CGFloat = 12
    static let composerFieldPaddingV: CGFloat = 8
    static let composerLineLimit = 1...6

    // MARK: - Attachments

    static let attachmentThumbnailSize: CGFloat = 54
    static let attachmentThumbnailRadius: CGFloat = 8
    /// Cap for a photo inside a bubble: never taller than this, and never wider
    /// than the bubble minus its padding.
    static let imageMaxHeight: CGFloat = 320
}
