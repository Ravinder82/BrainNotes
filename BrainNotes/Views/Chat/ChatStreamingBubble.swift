import SwiftUI

/// The in-flight reply, drawn as a live status console.
///
/// Deliberately its own view: it reads `engine.streamingText` and
/// `engine.streamProgress` directly, so an arriving token re-renders this
/// bubble and nothing else in the thread. When the stream finishes the message
/// is inserted into the store and this bubble is replaced by an ordinary row.
///
/// The console answers the three questions a bare typing indicator never did:
/// *who* is writing (avatar + name), *through what* (provider + model), and
/// *where it is* (a four-step track from connecting to saved, each step a real
/// engine event, with elapsed time and a live character count). Captain's
/// console wears a sonar sweep around the helm; other bots get the same
/// console with a plain pulse.
///
/// The streamed text parses on every paint through the same two-tier path as a
/// finished message: plain prose skips the parser entirely, and no cache key is
/// passed because the text changes on every token. Unterminated markup — a
/// `**bold` still waiting for its closer — renders literally, so content that
/// is already on screen never reflows when the closing marker finally arrives.
struct ChatStreamingBubble: View {
    let bot: Bot
    let engine: ChatEngine

    @Environment(\.colorScheme) private var scheme

    private var maxBubbleWidth: CGFloat {
        ChatLayout.maxBubbleWidth(in: DeviceMetrics.screenWidth)
    }

    private var shape: BubbleShape {
        BubbleShape(isOutgoing: false, tail: true)
    }

    private var isCaptain: Bool { bot.id == CaptainProfile.id }

    var body: some View {
        ChatBubbleLayout(maxWidth: maxBubbleWidth,
                         oppositeInset: ChatLayout.oppositeSideMinInset,
                         isOutgoing: false) {
            bubble
        }
        .sensoryFeedback(.impact(flexibility: .soft),
                         trigger: engine.streamProgress?.stage == .writing)
    }

    private var bubble: some View {
        content
            .background {
                shape.fill(Theme.incomingBubble(scheme))
                    .shadow(color: Theme.bubbleShadow(scheme), radius: 0.5, y: 0.5)
            }
            .overlay {
                shape.stroke(Theme.bubbleBorder(scheme), lineWidth: 0.5)
            }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            consoleHeader
            stageTrack
            statusLine

            if !engine.streamingText.isEmpty {
                Divider()
                    .padding(.vertical, 2)
                MessageBodyView(analysis: MessageContent.analyse(engine.streamingText))
                    .accessibilityLabel(Text(engine.streamingText))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(minWidth: 228, alignment: .leading)
        .accessibilityIdentifier("streaming-console")
    }

    // MARK: - Who is working

    /// Avatar (sonar-swept for Captain), name, and the wire the reply is
    /// travelling: provider and model, exactly as configured.
    private var consoleHeader: some View {
        HStack(spacing: 8) {
            WorkingAvatar(bot: bot, sonar: isCaptain)

            VStack(alignment: .leading, spacing: 1) {
                Text(bot.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.bubbleText(scheme))
                Text(providerAndModel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.bubbleMeta(scheme))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            elapsedBadge
        }
    }

    private var providerAndModel: String {
        guard let progress = engine.streamProgress else { return "" }
        return "\(progress.providerLabel) · \(progress.model)"
    }

    /// Seconds since the send left the device, live.
    private var elapsedBadge: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let started = engine.streamProgress?.startedAt ?? timeline.date
            let seconds = max(0, Int(timeline.date.timeIntervalSince(started)))
            Text(elapsedText(seconds))
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.bubbleMeta(scheme))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Theme.bubbleMeta(scheme).opacity(0.12),
                            in: Capsule())
        }
    }

    private func elapsedText(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let rest = seconds % 60
        return minutes > 0
            ? String(format: "%d:%02d", minutes, rest)
            : String(format: "0:%02d", rest)
    }

    // MARK: - Where the reply is

    /// The four real steps of a reply: reach the provider, wait for the first
    /// token, stream the body, save the result. The current step pulses;
    /// finished steps seal with a checkmark.
    private var stageTrack: some View {
        let current = engine.streamProgress?.stage.stepNumber ?? 1
        return HStack(spacing: 0) {
            ForEach(1...4, id: \.self) { step in
                StageDot(state: step < current ? .done
                         : step == current ? .active : .pending)
                if step < 4 {
                    StepConnector(walked: step < current)
                }
            }
        }
        .accessibilityLabel(Text("Step \(current) of 4"))
    }

    // MARK: - What is happening

    /// The plain-language line: who is doing what right now, and how much has
    /// arrived once tokens are flowing.
    private var statusLine: some View {
        HStack(spacing: 6) {
            let stage = engine.streamProgress?.stage ?? .connecting
            Image(systemName: icon(for: stage))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 14)
                .contentTransition(.symbolEffect(.replace))
            Text(headline(for: stage))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.bubbleText(scheme))
                .contentTransition(.interpolate)
                .animation(.easeOut(duration: 0.18), value: stage)
            if stage != .writing {
                PulsingDots()
            }
        }
    }

    private func icon(for stage: ChatEngine.StreamStage) -> String {
        switch stage {
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .thinking: return "brain"
        case .writing: return "pencil.and.scribble"
        case .finishing: return "checkmark.seal"
        }
    }

    private func headline(for stage: ChatEngine.StreamStage) -> String {
        let progress = engine.streamProgress
        switch stage {
        case .connecting:
            return "Contacting \(progress?.providerLabel ?? "provider")…"
        case .thinking:
            return "\(bot.name) is thinking…"
        case .writing:
            let count = progress?.receivedCharacters ?? engine.streamingText.count
            return "Writing — \(count.formatted()) chars"
        case .finishing:
            return "Wrapping up…"
        }
    }
}

// MARK: - Working avatar

/// The bot's avatar with a working signal: Captain gets a helm sonar — one
/// conic sweep rotating around the badge with a soft expanding ring — other
/// bots get a single breathing pulse. Only drawn while a stream is live, so
/// the animation never runs on an idle screen.
private struct WorkingAvatar: View {
    let bot: Bot
    let sonar: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                if sonar {
                    // Expanding range ring, 2.4 s sweep.
                    Circle()
                        .stroke(Theme.accent.opacity(ringOpacity(at: t)), lineWidth: 1.5)
                        .frame(width: 34 + ringGrowth(at: t), height: 34 + ringGrowth(at: t))
                    // Rotating conic sweep — the radar hand.
                    Circle()
                        .stroke(
                            AngularGradient(
                                colors: [.clear, Theme.accent.opacity(0.9)],
                                center: .center,
                                startAngle: .degrees(0),
                                endAngle: .degrees(90)),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: 38, height: 38)
                        .rotationEffect(.degrees((t * 150).truncatingRemainder(dividingBy: 360)))
                } else {
                    Circle()
                        .stroke(Theme.accent.opacity(pulse(at: t)), lineWidth: 2)
                        .frame(width: 34, height: 34)
                }
                BotAvatar(bot: bot, size: 26)
            }
            .frame(width: 40, height: 40)
        }
    }

    /// 0…1 growth of the range ring over its cycle.
    private func ringGrowth(at t: TimeInterval) -> CGFloat {
        let phase = (t.truncatingRemainder(dividingBy: 2.4)) / 2.4
        return 10 * phase
    }

    private func ringOpacity(at t: TimeInterval) -> Double {
        let phase = (t.truncatingRemainder(dividingBy: 2.4)) / 2.4
        return 0.55 * (1 - phase)
    }

    private func pulse(at t: TimeInterval) -> Double {
        0.35 + 0.3 * (0.5 + 0.5 * sin(t * 3.2))
    }
}

// MARK: - Stage track pieces

private enum StageDotState {
    case done, active, pending
}

/// One step of the reply's journey.
private struct StageDot: View {
    let state: StageDotState

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 14, height: 14)
                Image(systemName: "checkmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.white)
            case .active:
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let scale = 1 + 0.12 * sin(t * 5)
                    Circle()
                        .stroke(Theme.accent, lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 6, height: 6)
                        .scaleEffect(scale)
                }
                .frame(width: 14, height: 14)
            case .pending:
                Circle()
                    .fill(Color(.tertiaryLabel).opacity(0.4))
                    .frame(width: 8, height: 8)
                    .frame(width: 14, height: 14)
            }
        }
    }
}

/// The hairline between two steps; it fills with accent once the step to its
/// left is complete.
private struct StepConnector: View {
    let walked: Bool

    var body: some View {
        Capsule()
            .fill(walked ? Theme.accent : Color(.tertiaryLabel).opacity(0.3))
            .frame(height: 1.5)
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.25), value: walked)
    }
}

/// Compact trailing dots for the non-writing stages, cycled on the same
/// timeline cadence as the classic typing indicator.
private struct PulsingDots: View {
    private let step: Double = 0.3

    var body: some View {
        TimelineView(.periodic(from: .now, by: step)) { timeline in
            let phase = Int(timeline.date.timeIntervalSinceReferenceDate / step) % 3
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 4, height: 4)
                        .opacity(phase == index ? 1 : 0.3)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
