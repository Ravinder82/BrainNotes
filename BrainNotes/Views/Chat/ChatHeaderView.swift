import SwiftUI

/// The chat's navigation title: the contact's avatar, name and presence.
///
/// Tapping it opens the bot's info card, which is where a messenger puts the
/// same tap.
///
/// While a reply is streaming the presence line carries the real stage
/// ("thinking…", "writing · 1,204 chars") instead of a generic "typing…", so
/// the state of the work is visible even when the console is scrolled away.
struct ChatHeaderView: View {
    let bot: Bot
    /// True while this bot's own reply is streaming.
    let isTyping: Bool
    /// Stage-aware presence detail, supplied by the chat when streaming.
    var statusText: String?
    var onTap: () -> Void

    @Environment(\.colorScheme) private var scheme

    /// Short presence for the streaming bubble's stage, tuned for the
    /// one-line title slot.
    static func statusText(for progress: ChatEngine.StreamProgress?) -> String {
        guard let progress else { return "typing…" }
        switch progress.stage {
        case .connecting: return "contacting \(progress.providerLabel)…"
        case .thinking: return "thinking…"
        case .writing: return "writing · \(progress.receivedCharacters.formatted()) chars"
        case .finishing: return "wrapping up…"
        }
    }

    private var subtitle: String {
        isTyping ? (statusText ?? "typing…") : "online"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                BotAvatar(bot: bot, size: 32)

                VStack(alignment: .leading, spacing: 0) {
                    Text(bot.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(isTyping ? Theme.accentText(scheme)
                                         : Theme.mutedText(scheme))
                        .contentTransition(.interpolate)
                        .animation(.easeOut(duration: 0.18), value: subtitle)
                }
                .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(bot.name), \(subtitle)"))
        .accessibilityHint(Text("Shows contact info"))
    }
}
