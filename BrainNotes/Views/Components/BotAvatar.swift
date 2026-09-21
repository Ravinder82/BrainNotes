import SwiftUI

/// Circular avatar. Bots render an emoji on a tinted disc, mirroring how a
/// messaging app shows a contact photo with a fallback initial.
struct BotAvatar: View {
    let bot: Bot
    var size: CGFloat = 52

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: bot.avatarColorHex),
                            Color(hex: bot.avatarColorHex).opacity(0.72),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(bot.avatarEmoji)
                .font(.system(size: size * 0.5))
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            // Presence dot, always "online" for bots.
            Circle()
                .fill(Theme.unreadBadge)
                .frame(width: size * 0.24, height: size * 0.24)
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                .offset(x: 1, y: 1)
        }
        .accessibilityLabel("Avatar for \(bot.name)")
    }
}

/// Rounded search field used on the chat list, matching the messaging-app idiom.
struct SearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(.secondarySystemBackground), in: Capsule())
    }
}
