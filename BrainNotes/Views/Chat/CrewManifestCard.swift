import SwiftUI

/// The card a Captain reply grows when Captain has assembled a crew: the
/// machine-readable action block becomes a human roster — one crew section
/// per `create_crew` action with each member on their own row.
///
/// The raw `confabula-actions` JSON never renders in the thread; it is the
/// contract between Captain and the store, not something a reader should
/// have to look at.
///
/// When Captain emits a lone `create_specialist` (the rare fallback), the
/// card degrades gracefully: the single specialist renders in the same shape
/// inside a "lone specialist" section so the reader sees one consistent
/// surface.
struct CrewManifestCard: View {
    let actions: [CaptainAction]
    /// Set when the block failed validation: the card explains rather than
    /// silently showing an empty roster.
    var failure: String? = nil

    @Environment(\.crewLookup) private var crewLookup
    @Environment(\.colorScheme) private var scheme

    /// Crews the action emitted, with their declared members in order.
    private var crewActions: [CaptainAction.CreateCrew] {
        actions.compactMap { action in
            if case .createCrew(let spec) = action { return spec }
            return nil
        }
    }

    /// Lone specialists the action emitted (no enclosing crew).
    private var loneSpecialists: [CaptainAction.CreateSpecialist] {
        actions.compactMap { action in
            if case .createSpecialist(let spec) = action { return spec }
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader
            if let failure {
                Text(failure)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
            } else if !crewActions.isEmpty || !loneSpecialists.isEmpty {
                ForEach(Array(crewActions.enumerated()), id: \.offset) { idx, crew in
                    if idx > 0 || !loneSpecialists.isEmpty { sectionDivider }
                    crewSection(crew)
                }
                if !loneSpecialists.isEmpty {
                    if !crewActions.isEmpty { sectionDivider }
                    loneSpecialistsSection
                }
            }
        }
        .background(Theme.raised(scheme),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.hairline(scheme), lineWidth: 1)
        }
        // Keep the card's own identifier from leaking onto every child row:
        // `contain` makes the card a real accessibility container, so the
        // header and the member rows keep their own identifiers/labels.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("crew-manifest-card")
    }

    // MARK: - Header

    private var cardHeader: some View {
        let totalCrews = crewActions.count
        let totalMembers = crewActions.reduce(0) { $0 + $1.members.count }
            + loneSpecialists.count
        return HStack(spacing: 6) {
            Image(systemName: "person.3.sequence.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(headerTitle(crewCount: totalCrews, memberCount: totalMembers))
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(0.3)
            Spacer(minLength: 4)
            Image(systemName: "helm")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(Theme.accentText(scheme))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func headerTitle(crewCount: Int, memberCount: Int) -> String {
        if crewCount == 0 {
            if memberCount == 1 { return "Specialist joined the crew" }
            return "\(memberCount) specialists joined the crew"
        }
        if memberCount == 0 { return "Crew assembled" }
        if crewCount == 1 {
            return "Crew assembled · \(memberCount) specialist\(memberCount == 1 ? "" : "s")"
        }
        return "\(crewCount) crews · \(memberCount) specialists"
    }

    // MARK: - Crew section

    private func crewSection(_ crew: CaptainAction.CreateCrew) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(crew.emoji)
                    .font(.system(size: 14))
                    .frame(width: 26, height: 26)
                    .background(Color(hex: crew.accentColorHex).opacity(0.18),
                                in: Circle())
                    .overlay(Circle().stroke(Color(hex: crew.accentColorHex).opacity(0.55),
                                              lineWidth: 1))
                VStack(alignment: .leading, spacing: 1) {
                    Text(crew.name)
                        .font(.system(size: 13, weight: .semibold))
                    Text(crew.mission)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

            ForEach(Array(crew.members.enumerated()), id: \.offset) { idx, spec in
                if idx > 0 { rowDivider }
                SpecialistRow(spec: spec, bot: crewLookup.byName[spec.name.lowercased()])
            }
        }
    }

    private var loneSpecialistsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "person.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("LONE SPECIALIST")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
            ForEach(Array(loneSpecialists.enumerated()), id: \.offset) { idx, spec in
                if idx > 0 { rowDivider }
                SpecialistRow(spec: spec, bot: crewLookup.byName[spec.name.lowercased()])
            }
        }
    }

    // MARK: - Dividers

    private var sectionDivider: some View {
        Divider()
            .padding(.vertical, 4)
    }

    private var rowDivider: some View {
        // Aligns to the text column: 12pt row inset + 30pt avatar + 10pt gap.
        Divider()
            .padding(.leading, 52)
    }
}

/// One specialist on the manifest: avatar, name, mission, and a chevron that
/// opens their private chat when they exist in the store.
private struct SpecialistRow: View {
    let spec: CaptainAction.CreateSpecialist
    let bot: Bot?

    var body: some View {
        Group {
            if let bot {
                NavigationLink {
                    ChatView(bot: bot)
                } label: {
                    rowLabel(interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Specialist \(spec.name), \(spec.role)"))
                .accessibilityIdentifier("crew-member-\(spec.name)")
            } else {
                rowLabel(interactive: false)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("Specialist \(spec.name), \(spec.role)"))
                    .accessibilityIdentifier("crew-member-\(spec.name)")
            }
        }
    }

    /// A stable identity glyph per specialist: same name always earns the
    /// same emoji and tint, so the crew stays visually recognisable across
    /// messages without a store lookup.
    private var identity: (emoji: String, tint: Color) {
        let emojis = ["🧭", "🔭", "🛰️", "📡", "⚗️", "🧠", "🦉", "🗂️", "⚙️", "🎯"]
        var hash: UInt64 = 5381
        for byte in spec.name.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        let emoji = emojis[Int(hash % UInt64(emojis.count))]
        let hex = Theme.defaultAvatarHexes[Int(hash % UInt64(Theme.defaultAvatarHexes.count))]
        return (emoji, Color(hex: hex))
    }

    private func rowLabel(interactive: Bool) -> some View {
        HStack(spacing: 10) {
            Text(identity.emoji)
                .font(.system(size: 15))
                .frame(width: 30, height: 30)
                .background(identity.tint.opacity(0.18), in: Circle())
                .overlay(Circle().stroke(identity.tint.opacity(0.55), lineWidth: 1))

            VStack(alignment: .leading, spacing: 1) {
                Text(spec.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(spec.role)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 6)

            if interactive {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}