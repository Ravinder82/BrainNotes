import SwiftUI

/// The three dots shown while a reply is on its way.
///
/// Driven by `TimelineView` rather than a timer subscription: the timeline only
/// redraws the dots while they are on screen, and it creates no per-instance
/// timer to invalidate.
struct TypingIndicator: View {
    /// Seconds per dot, so the full cycle is three steps.
    private let step: Double = 0.28

    var body: some View {
        TimelineView(.periodic(from: .now, by: step)) { timeline in
            let phase = Int(timeline.date.timeIntervalSinceReferenceDate / step) % 3
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(.secondary)
                        .frame(width: 7, height: 7)
                        .offset(y: phase == index ? -3.5 : 0)
                        .opacity(phase == index ? 1 : 0.45)
                }
            }
            .animation(.easeInOut(duration: step * 0.8), value: phase)
        }
        .accessibilityLabel(Text("Typing"))
    }
}
