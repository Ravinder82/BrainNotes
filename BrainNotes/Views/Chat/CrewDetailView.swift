import SwiftUI
import SwiftData

/// The crew detail screen — what opens when you tap a `CrewCard`.
///
/// Reads as a mission briefing: the crew's identity at the top (the same
/// `CrewCard` you tapped, only bigger), then each member on their own row so
/// you can jump straight into a private 1:1 with the specialist doing the
/// work. A "Talk to Captain" footer hands the user back to Chief of Staff for
/// new instructions.
struct CrewDetailView: View {
    @Bindable var crew: Crew

    @Environment(\.modelContext) private var context
    @Environment(ChatEngine.self) private var engine
    @Environment(\.colorScheme) private var scheme

    @State private var showDisbandConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerCard
                membersSection
                captainFooter
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(Theme.chatBackground(scheme).ignoresSafeArea())
        .navigationTitle(crew.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        crew.isPinned.toggle()
                        try? context.save()
                    } label: {
                        Label(crew.isPinned ? "Unpin" : "Pin",
                              systemImage: crew.isPinned ? "pin.slash" : "pin")
                    }
                    Button(role: .destructive) {
                        showDisbandConfirm = true
                    } label: {
                        Label("Disband crew", systemImage: "person.3.fill.xmark")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Crew options")
            }
        }
        .confirmationDialog(
            "Disband \(crew.name)?",
            isPresented: $showDisbandConfirm,
            titleVisibility: .visible
        ) {
            Button("Disband", role: .destructive) {
                context.delete(crew)
                try? context.save()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The crew and its shared history are removed. Specialists stay; they can join other crews.")
        }
    }

    // MARK: - Header card

    /// A full-width version of the crew identity: big emoji, name, mission
    /// and the live status pill. Stretched variant of the rail card so the
    /// detail screen has a clear "this is the crew you're inside" anchor.
    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                avatar
                VStack(alignment: .leading, spacing: 4) {
                    Text(crew.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text("Crew · assembled by Captain")
                        .font(.caption.weight(.semibold))
                        .tracking(0.3)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                Spacer()
                statusBadge
            }
            Divider()
            Text(crew.mission)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            statsRow
        }
        .padding(18)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(borderColor, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private var avatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.95), tint.opacity(0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 64, height: 64)
            Text(crew.emoji)
                .font(.system(size: 34))
        }
        .frame(width: 64, height: 64)
    }

    private var statusBadge: some View {
        let working = workingMembers.count
        let label: String
        let isLive = working > 0
        if working == 0 {
            label = "All idle"
        } else if working == 1 {
            label = "1 working"
        } else {
            label = "\(working) working"
        }
        return HStack(spacing: 5) {
            if isLive {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
            } else {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isLive ? tint : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            (isLive ? tint.opacity(0.14) : Color(.tertiarySystemFill)),
            in: Capsule()
        )
    }

    /// Three pieces of crew metadata on one row — member count, mission age,
    /// working count — so the header reads as a one-glance dashboard.
    private var statsRow: some View {
        HStack(spacing: 18) {
            stat(value: "\(crew.orderedMembers.count)",
                 label: "Specialists",
                 systemImage: "person.2.fill")
            stat(value: ageLabel,
                 label: "On deck",
                 systemImage: "calendar")
            stat(value: "\(workingMembers.count)",
                 label: "Working",
                 systemImage: "bolt.fill")
        }
    }

    private func stat(value: String, label: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
        }
    }

    private var ageLabel: String {
        let cal = Calendar.current
        let date = crew.createdAt
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 7 { return "\(days)d ago" }
        if days < 30 { return "\(days / 7)w ago" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    // MARK: - Members section

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Specialists", count: crew.orderedMembers.count,
                         systemImage: "person.fill")
            VStack(spacing: 8) {
                ForEach(crew.orderedMembers) { bot in
                    NavigationLink {
                        ChatView(bot: bot)
                    } label: {
                        MemberRow(bot: bot,
                                  isWorking: workingBotIDs.contains(bot.id))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Captain footer

    /// Closing block reminding the user Captain is free and pointing back to
    /// him for the next instruction. Same accent treatment as the crew card
    /// so the footer reads as a continuation, not a separate component.
    private var captainFooter: some View {
        HStack(spacing: 12) {
            Image(systemName: "helm")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .background(Theme.accent.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Captain stays free")
                    .font(.subheadline.weight(.semibold))
                Text("Open Captain to delegate the next step to this crew.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            NavigationLink {
                captainDestination
            } label: {
                Image(systemName: "arrow.up.right.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.accent)
            }
            .accessibilityLabel("Open Captain")
        }
        .padding(14)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 16))
    }

    /// Resolves (and lazily creates) the Captain bot so the link does not
    /// need a navigation destination in the parent stack.
    @ViewBuilder
    private var captainDestination: some View {
        CaptainChatLoader()
    }

    // MARK: - Helpers

    private func sectionTitle(_ text: String,
                              count: Int,
                              systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(text.uppercased()) · \(count)")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var tint: Color { Color(hex: crew.accentColorHex) }

    private var workingBotIDs: Set<UUID> {
        guard let id = engine.streamingBotID else { return [] }
        return [id]
    }

    private var workingMembers: [Bot] {
        crew.orderedMembers.filter { workingBotIDs.contains($0.id) }
    }

    private var cardBackground: Color {
        scheme == .dark
            ? Color(.secondarySystemBackground)
            : Color(.systemBackground)
    }

    private var borderColor: Color {
        let alpha: Double = scheme == .dark ? 0.18 : 0.12
        return tint.opacity(alpha)
    }
}

/// One row inside the crew's roster: avatar, name, role, working dot and a
/// chevron that opens the specialist's private chat.
private struct MemberRow: View {
    let bot: Bot
    let isWorking: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                BotAvatar(bot: bot, size: 44)
                if isWorking {
                    Circle()
                        .fill(Theme.unreadBadge)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                        .offset(x: 1, y: 1)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(bot.name)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(bot.role.isEmpty ? "Specialist" : bot.role)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(bot.name), \(bot.role)"))
        .accessibilityValue(Text(isWorking ? "Working" : "Ready"))
        .accessibilityHint(Text("Opens private chat with this specialist"))
    }
}

/// Resolves (and lazily creates) the Captain bot. Lives in a tiny view so the
/// footer link can `NavigationLink` straight to it without needing the parent
/// stack to know about Captain's id. Mirrors `ChatListView.openCaptain`.
private struct CaptainChatLoader: View {
    @Environment(\.modelContext) private var context
    @State private var captain: Bot?

    var body: some View {
        Group {
            if let captain {
                ChatView(bot: captain)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { resolve() }
    }

    private func resolve() {
        do {
            let captainID = CaptainProfile.id
            let descriptor = FetchDescriptor<Bot>(predicate: #Predicate { $0.id == captainID })
            if let existing = try context.fetch(descriptor).first {
                captain = existing
                return
            }
            let new = CaptainProfile.makeBot()
            context.insert(new)
            try context.save()
            captain = new
        } catch {
            // Surface as an empty state rather than silently failing.
            captain = nil
        }
    }
}