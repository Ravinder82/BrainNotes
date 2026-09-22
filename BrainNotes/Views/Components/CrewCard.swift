import SwiftUI

/// The group card. One card = one crew.
///
/// Designed against the iOS 18 / HIG rules and the WhatsApp / Telegram /
/// GroupMe convention for stacked member avatars. The card is the same unit
/// everywhere it appears (chat-list rail, crew deck, manifest surface) so the
/// user can read it without re-learning the layout.
///
/// Anatomy (top to bottom):
///   1. Header row — emoji on a tinted concentric disc, crew name, status pill
///      ("N working" / "All idle").
///   2. Mission line — the crew's one-line purpose, secondary text, two-line
///      limit so the card height stays predictable.
///   3. Member stack — up to four overlapping 22pt avatars + a "+N" overflow.
///      The order matches the crew's `orderedMembers` so the card shows the
///      specialists Captain listed first.
///
/// ## Dimensions
/// The default `cardSize` is `.regular` (180 × 196 pt). That's the size that
/// fits two cards per row in the chat-list rail with 16 pt gutters and 16 pt
/// outer padding on an iPhone 15 (393 pt wide). Two cards per row matches the
/// WhatsApp and Apple HIG recommended density for content lists where each
/// item carries a name and a tagline.
///
///   - width:  180 pt   (fits 2× in iPhone portrait with 16 pt gutters)
///   - height: 196 pt   (4-line text budget: title + 2-line mission + stack)
///   - corner: 18 pt (slightly tighter than the chat list rows; matches iOS 18
///             container recommendations for grouped content)
///   - avatar disc: 44 pt  (≥ 44 pt minimum touch target reached on the
///                      container itself, which is tappable end-to-end)
///   - status pill: 26 pt tall, capsule
///
/// `.compact` is 168 × 168 pt for surfaces that already carry extra chrome
/// (the crew deck rail, the Captain manifest card's footer).
///
/// ## Accessibility
/// The whole card is a single accessibility element with a label that reads
/// "Crew Content Squad, mission …, 5 specialists, 3 working". VoiceOver does
/// not need to traverse the inner stack.
struct CrewCard: View {
    let crew: Crew
    /// Bots currently streaming — used to draw the live "N working" pill.
    var workingBotIDs: Set<UUID> = []
    var style: Style = .regular

    @Environment(\.colorScheme) private var scheme

    enum Style {
        /// 180 × 196 pt — the chat-list grid card.
        case regular
        /// 168 × 168 pt — the deck rail and the manifest footer.
        case compact
    }

    private var metrics: Metrics {
        switch style {
        case .regular: return Metrics(width: 180, height: 196,
                                      cornerRadius: 18,
                                      avatarSize: 44,
                                      memberSize: 22,
                                      memberOverlap: 12,
                                      padding: 14,
                                      spacing: 10,
                                      missionLineLimit: 2,
                                      showMission: true)
        case .compact: return Metrics(width: 168, height: 168,
                                      cornerRadius: 16,
                                      avatarSize: 40,
                                      memberSize: 20,
                                      memberOverlap: 10,
                                      padding: 12,
                                      spacing: 8,
                                      missionLineLimit: 1,
                                      showMission: true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing) {
            header
            if metrics.showMission {
                mission
            }
            memberStack
        }
        .padding(metrics.padding)
        .frame(width: metrics.width, height: metrics.height, alignment: .topLeading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: metrics.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: metrics.cornerRadius)
                .stroke(borderColor, lineWidth: 1)
        )
        .shadow(color: Theme.cardShadow(scheme), radius: 10, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(Text("Opens the crew"))
        .accessibilityIdentifier("crew-card-\(crew.id.uuidString)")
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            avatar
            Spacer(minLength: 4)
            statusPill
        }
    }

    private var avatar: some View {
        ZStack {
            // Concentric inner disc so the card edges feel iOS 18 native
            // (WWDC25: nested containers should share a corner family).
            RoundedRectangle(cornerRadius: metrics.avatarSize * 0.28,
                             style: .continuous)
                .fill(tint.opacity(scheme == .dark ? 0.32 : 0.16))
                .frame(width: metrics.avatarSize, height: metrics.avatarSize)
                .overlay(
                    RoundedRectangle(cornerRadius: metrics.avatarSize * 0.28,
                                     style: .continuous)
                        .stroke(tint.opacity(0.55), lineWidth: 1.5)
                )
            Text(crew.emoji)
                .font(.system(size: metrics.avatarSize * 0.52))
        }
        .frame(width: metrics.avatarSize, height: metrics.avatarSize)
        .overlay(alignment: .bottomTrailing) {
            // Tiny stack badge so the avatar reads as "this is a group" even
            // before the member stack below.
            Image(systemName: "person.2.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(3)
                .background(Theme.accentDeep, in: Circle())
                .overlay(Circle().stroke(cardBackground, lineWidth: 1.5))
                .offset(x: 2, y: 2)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Status pill

    /// "3 working" / "All idle" — the only live indicator on the card.
    /// Drives the user's first scan: who needs attention right now.
    private var statusPill: some View {
        let working = workingMembers.count
        let label: String
        let isLive = working > 0
        if working == 0 {
            label = "Idle"
        } else if working == 1 {
            label = "1 working"
        } else {
            label = "\(working) working"
        }
        return HStack(spacing: 4) {
            if isLive {
                Circle()
                    .fill(Theme.live)
                    .frame(width: 6, height: 6)
            } else {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.mutedText(scheme))
            }
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.2)
                .foregroundStyle(isLive ? Color.white : Theme.mutedText(scheme))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: 22)
        .background(
            (isLive
                ? Theme.accentDeep
                : (scheme == .dark ? Color.white.opacity(0.08)
                                   : Color(hex: "EFEAE2"))),
            in: Capsule()
        )
        .accessibilityHidden(true)
    }

    // MARK: - Mission

    private var mission: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(crew.name)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .accessibilityHidden(true)
            Text(crew.mission)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(metrics.missionLineLimit)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Member stack

    /// Overlapping 22pt avatars. Up to four show plus a "+N" overflow chip so
    /// the width never grows past the card padding. The order is the crew's
    /// own ordering, not alphabetical — Captain's roster tells the story.
    private var memberStack: some View {
        HStack(spacing: -metrics.memberOverlap) {
            ForEach(visibleMembers) { bot in
                memberBadge(for: bot)
            }
            if overflowCount > 0 {
                overflowBadge
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func memberBadge(for bot: Bot) -> some View {
        Text(bot.avatarEmoji)
            .font(.system(size: metrics.memberSize * 0.5))
            .frame(width: metrics.memberSize, height: metrics.memberSize)
            .background(
                Color(hex: bot.avatarColorHex).opacity(0.85),
                in: Circle()
            )
            .overlay(
                Circle().stroke(cardBackground, lineWidth: 1.5)
            )
            .overlay(alignment: .bottomTrailing) {
                if workingBotIDs.contains(bot.id) {
                    Circle()
                        .fill(Theme.live)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(cardBackground, lineWidth: 1.2))
                        .offset(x: 1, y: 1)
                }
            }
    }

    private var overflowBadge: some View {
        Text("+\(overflowCount)")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: metrics.memberSize, height: metrics.memberSize)
            .background(Color(.tertiarySystemFill), in: Circle())
            .overlay(Circle().stroke(cardBackground, lineWidth: 1.5))
    }

    // MARK: - Derived data

    private var members: [Bot] { crew.orderedMembers }

    private var visibleMembers: [Bot] {
        Array(members.prefix(4))
    }

    private var overflowCount: Int {
        max(0, members.count - visibleMembers.count)
    }

    private var workingMembers: [Bot] {
        members.filter { workingBotIDs.contains($0.id) }
    }

    // MARK: - Style tokens

    private var tint: Color { Color(hex: crew.accentColorHex) }

    /// The card's fill. Light mode lifts off the wallpaper; dark mode sinks
    /// slightly so the border can do the work.
    private var cardBackground: Color {
        Theme.raised(scheme)
    }

    private var borderColor: Color {
        Theme.hairline(scheme)
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        let missionText = crew.mission.isEmpty ? "no mission set" : crew.mission
        let specialistWord = members.count == 1 ? "specialist" : "specialists"
        let workingText = workingMembers.count == 0
            ? "all idle"
            : "\(workingMembers.count) working"
        return "Crew \(crew.name). Mission: \(missionText). "
             + "\(members.count) \(specialistWord), \(workingText)."
    }

    private struct Metrics {
        let width: CGFloat
        let height: CGFloat
        let cornerRadius: CGFloat
        let avatarSize: CGFloat
        let memberSize: CGFloat
        let memberOverlap: CGFloat
        let padding: CGFloat
        let spacing: CGFloat
        let missionLineLimit: Int
        let showMission: Bool
    }
}

extension CrewCard {
    /// Compact horizontal card for the crew deck rail. Different proportions
    /// from the regular card because the rail already scrolls horizontally —
    /// width matters more than height.
    static func compact(_ crew: Crew,
                        workingBotIDs: Set<UUID> = []) -> some View {
        CrewCard(crew: crew, workingBotIDs: workingBotIDs, style: .compact)
    }
}

#Preview("Regular") {
    let captainID = UUID()
    let bots = (0..<4).map { i in
        let b = Bot(name: "Specialist \(i + 1)",
                    avatarEmoji: ["🔭","🎬","🛡️","✍️"][i],
                    avatarColorHex: ["6A5ACD","E67E22","16A085","C0392B"][i])
        b.isCaptainManaged = true
        return b
    }
    let crew = Crew(name: "Content Squad",
                    mission: "Turns this week's AI trends into short-form video scripts.",
                    emoji: "🎬",
                    accentColorHex: "00A884",
                    members: bots,
                    assembledByID: captainID)
    return CrewCard(crew: crew, workingBotIDs: [bots[1].id])
        .padding()
        .background(Color(.systemGroupedBackground))
}

#Preview("Compact") {
    let bots = (0..<3).map { i in
        let b = Bot(name: "S\(i + 1)",
                    avatarEmoji: ["📚","✅","🔭"][i],
                    avatarColorHex: ["2980B9","16A085","6A5ACD"][i])
        b.isCaptainManaged = true
        return b
    }
    let crew = Crew(name: "Research Crew",
                    mission: "Sources and verifies facts before any draft ships.",
                    emoji: "🧪",
                    accentColorHex: "6A5ACD",
                    members: bots)
    return HStack(spacing: 12) {
        CrewCard(crew: crew, workingBotIDs: [], style: .compact)
        CrewCard(crew: crew, workingBotIDs: Set(bots.map(\.id)), style: .compact)
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}