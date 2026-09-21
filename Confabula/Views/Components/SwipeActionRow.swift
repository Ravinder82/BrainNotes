import SwiftUI
import UIKit

/// Swipe-left-to-delete for a single chat row.
///
/// SwiftUI's `.swipeActions` only works inside a `List`, and a `List` cannot
/// carry the chat wallpaper or per-bubble layout, so the gesture is implemented
/// here: drag left to reveal Delete, or keep dragging past the threshold to
/// delete in one motion.
///
/// The recogniser is a UIKit pan rather than a SwiftUI `DragGesture`, and that
/// is the point of this type. A `DragGesture` on every row competes directly
/// with the enclosing scroll view's pan; which one wins depends on which crosses
/// its threshold first, and the two are close enough that vertical scrolling
/// would sometimes be captured by a row and stop dead. A pan that refuses to
/// begin unless the drag is clearly horizontal can never win a vertical drag, so
/// scrolling is decided by geometry instead of a race.
struct SwipeActionRow<Content: View>: View {
    let id: UUID
    /// Shared so only one row can sit open at a time.
    @Binding var openRow: UUID?
    var onDelete: () -> Void
    /// In selection mode swiping is disabled and a tap toggles selection.
    var selectionMode: Bool = false
    var isSelected: Bool = false
    var onToggleSelect: (() -> Void)?
    /// Called on a tap that is not a selection toggle. The chat uses it to put
    /// the keyboard away.
    var onTap: (() -> Void)?
    @ViewBuilder var content: Content

    @State private var offset: CGFloat = 0

    /// How far the row slides to park the Delete button on screen.
    private let revealWidth: CGFloat = 84
    /// Drag distance that commits the delete without a second tap.
    private let fullSwipeThreshold: CGFloat = 150
    /// Elastic travel allowed past the reveal point.
    private let overshoot: CGFloat = 46
    /// A drag past this much of the reveal width parks the row open.
    private let openThreshold: CGFloat = 0.6

    private var isOpen: Bool { openRow == id }

    var body: some View {
        ZStack(alignment: .trailing) {
            if !selectionMode {
                deleteButton
            }

            HStack(spacing: 8) {
                if selectionMode {
                    selectionMark
                }
                content
                    .allowsHitTesting(!selectionMode)
            }
            .contentShape(Rectangle())
            .offset(x: offset)
            .gesture(swipe)
            .gesture(RowTapGesture {
                if selectionMode {
                    onToggleSelect?()
                } else {
                    onTap?()
                }
            })
        }
        .onChange(of: openRow) { _, newValue in
            // Another row opened; slide this one shut.
            if newValue != id, offset != 0 {
                withAnimation(.snappy(duration: 0.22)) { offset = 0 }
            }
        }
        .onChange(of: selectionMode) { _, active in
            if active, offset != 0 {
                withAnimation(.snappy(duration: 0.22)) { offset = 0 }
            }
        }
    }

    /// Revealed by the swipe. Hidden by opacity as well as by the content that
    /// covers it, so it can never flash on screen before the drag starts.
    private var deleteButton: some View {
        Button(role: .destructive, action: delete) {
            Image(systemName: "trash")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: revealWidth)
                .frame(maxHeight: .infinity)
                .background(Color.red)
                .clipShape(RoundedRectangle(cornerRadius: ChatLayout.bubbleCornerRadius))
        }
        .buttonStyle(.plain)
        .opacity(offset < -6 ? 1 : 0)
        .accessibilityLabel(Text("Delete message"))
    }

    private var selectionMark: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 21))
            .foregroundStyle(isSelected ? Theme.accent : Color(.tertiaryLabel))
            .accessibilityHidden(true)
    }

    private var swipe: HorizontalSwipeGesture {
        HorizontalSwipeGesture(
            isEnabled: !selectionMode,
            onChanged: { translation in
                let base: CGFloat = isOpen ? -revealWidth : 0
                offset = min(0, max(base + translation, -(revealWidth + overshoot)))
            },
            onEnded: { translation, velocity in
                let base: CGFloat = isOpen ? -revealWidth : 0
                // Project a short distance along the release velocity so a fast
                // flick commits without needing the full drag distance.
                let projected = base + translation + velocity * 0.12

                if projected <= -fullSwipeThreshold {
                    delete()
                } else if offset <= -revealWidth * openThreshold {
                    withAnimation(.snappy(duration: 0.22)) { offset = -revealWidth }
                    openRow = id
                } else {
                    close()
                }
            }
        )
    }

    private func close() {
        withAnimation(.snappy(duration: 0.22)) { offset = 0 }
        if isOpen { openRow = nil }
    }

    private func delete() {
        withAnimation(.easeOut(duration: 0.18)) { offset = 0 }
        if isOpen { openRow = nil }
        onDelete()
    }
}

@MainActor
enum RowTouchPolicy {
    static func isInteractive(_ view: UIView?) -> Bool {
        var current = view
        while let candidate = current {
            if candidate is UITextView || candidate is UIControl { return true }
            current = candidate.superview
        }
        return false
    }
}

private struct RowTapGesture: UIGestureRecognizerRepresentable {
    var onTap: () -> Void

    func makeUIGestureRecognizer(context: Context) -> RowTapRecognizer {
        RowTapRecognizer()
    }

    func handleUIGestureRecognizerAction(_ recognizer: RowTapRecognizer, context: Context) {
        if recognizer.state == .ended { onTap() }
    }
}

private final class RowTapRecognizer: UITapGestureRecognizer, UIGestureRecognizerDelegate {
    init() {
        super.init(target: nil, action: nil)
        delegate = self
        cancelsTouchesInView = false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        !RowTouchPolicy.isInteractive(touch.view)
    }
}

/// Bridges a direction-locked pan into SwiftUI.
///
/// `UIGestureRecognizerRepresentable` is iOS 18+, which matches the deployment
/// target.
struct HorizontalSwipeGesture: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    /// Horizontal translation, in points, during the drag.
    var onChanged: (CGFloat) -> Void
    /// Final translation and horizontal velocity on release.
    var onEnded: (CGFloat, CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> HorizontalPanRecognizer {
        HorizontalPanRecognizer()
    }

    func updateUIGestureRecognizer(_ recognizer: HorizontalPanRecognizer,
                                   context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: HorizontalPanRecognizer,
                                         context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .changed:
            onChanged(translation)
        case .ended:
            onEnded(translation, recognizer.velocity(in: recognizer.view).x)
        case .cancelled, .failed:
            onEnded(0, 0)
        default:
            break
        }
    }
}

/// A pan recogniser that declines anything that is not clearly horizontal.
///
/// By the time UIKit asks whether the gesture may begin, the drag has a
/// direction; anything steeper than roughly 40° is refused outright, which is
/// what stops a row from ever stealing a vertical scroll.
final class HorizontalPanRecognizer: UIPanGestureRecognizer,
                                     UIGestureRecognizerDelegate {
    /// Horizontal movement must exceed the vertical by this factor…
    private let directionBias: CGFloat = 1.6
    /// …and must be at least this fast, which filters out resting-finger noise.
    private let minimumSpeed: CGFloat = 60

    init() {
        super.init(target: nil, action: nil)
        delegate = self
        maximumNumberOfTouches = 1
        // A row swipe should feel immediate rather than wait for the tap to
        // time out.
        cancelsTouchesInView = false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        !RowTouchPolicy.isInteractive(touch.view)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let velocity = velocity(in: view)
        guard velocity != .zero else { return false }
        let horizontal = abs(velocity.x)
        let vertical = abs(velocity.y)
        return horizontal > vertical * directionBias && horizontal > minimumSpeed
    }

    /// Run alongside the scroll view's pan rather than forcing it to cancel.
    ///
    /// `gestureRecognizerShouldBegin` already excludes vertical drags, so
    /// recognising simultaneously cannot produce a fight — it only avoids a
    /// mid-scroll cancellation hitch on a fast diagonal flick.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}