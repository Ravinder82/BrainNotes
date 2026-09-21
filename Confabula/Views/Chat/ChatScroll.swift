import SwiftUI

/// Scroll bookkeeping for the thread, shared with its stream follower.
///
/// A reference type held in `@State` on purpose. These values are written on
/// every scroll frame by `onScrollGeometryChange`; as individual `@State`
/// properties they invalidated the whole chat body ~60 times a second, which is
/// what made scrolling sluggish.
@MainActor
final class ChatScrollState {
    /// Whether the thread is following the newest content. Once the user
    /// scrolls away from the bottom, automatic scrolling stops until they come
    /// back — a stream must never yank them out of what they are reading.
    var isPinnedToBottom = true

    /// Identifier of the zero-height view at the end of the thread.
    static let bottomAnchor = "chat-bottom-anchor"

    /// Throttles automatic scrolling to roughly the refresh rate, so a burst of
    /// streamed tokens cannot queue dozens of animations.
    private let minimumInterval: TimeInterval = 0.1
    private var lastScroll = Date.distantPast

    /// True at most once per `minimumInterval`.
    func mayScrollNow() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastScroll) > minimumInterval else {
            return false
        }
        lastScroll = now
        return true
    }
}

/// Follows a streaming reply to the bottom of the thread.
///
/// This view observes the engine itself and is zero-height, so an arriving token
/// invalidates only this view rather than the whole thread. It honours the pin:
/// if the user has scrolled up to read something, the stream leaves their
/// position alone.
struct StreamScrollFollower: View {
    let engine: ChatEngine
    let proxy: ScrollViewProxy
    let state: ChatScrollState

    var body: some View {
        Color.clear
            .frame(height: 0)
            .onChange(of: engine.streamingText) { _, _ in
                guard engine.isStreaming,
                      state.isPinnedToBottom,
                      state.mayScrollNow()
                else { return }
                proxy.scrollTo(ChatScrollState.bottomAnchor, anchor: .bottom)
            }
    }
}

/// Tap-anywhere-on-the-thread dismissal for the keyboard.
///
/// The wallpaper behind the scroll view cannot take this job: a scroll view
/// swallows every touch over its area, so the wallpaper only saw taps when the
/// thread was shorter than the screen. This recogniser sits on the scroll view
/// itself, stays out of the way of text selection and controls (same policy as
/// the row tap), and never cancels touches, so scrolling, links and the attach
/// menu are unaffected.
struct ThreadBackgroundTap: UIGestureRecognizerRepresentable {
    var onTap: () -> Void

    func makeUIGestureRecognizer(context: Context) -> ThreadTapRecognizer {
        ThreadTapRecognizer()
    }

    func handleUIGestureRecognizerAction(_ recognizer: ThreadTapRecognizer,
                                         context: Context) {
        if recognizer.state == .ended { onTap() }
    }
}

final class ThreadTapRecognizer: UITapGestureRecognizer, UIGestureRecognizerDelegate {
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delegate = self
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        // UITextView (message text, the composer field) and UIControl (menus,
        // links, buttons) keep their own taps; everything else counts as the
        // thread background and puts the keyboard away.
        !RowTouchPolicy.isInteractive(touch.view)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Per-row taps handle the same event (both just dismiss the keyboard);
        // forcing exclusivity here would eat one of them unpredictably.
        true
    }
}