import SwiftUI
import SwiftData

/// The main screen: a searchable list of bot conversations and Captain's
/// assembled crews, sorted with pinned items first and then by most recent
/// activity, exactly like a messenger's chat list.
///
/// Crews take the featured rail — one `CrewCard` per crew — so the user can
/// scan who is on what and tap straight into the crew detail. Lone bots
/// (user-created or one-off specialists) live in the regular list below.
    struct ChatListView: View {
        @Environment(\.modelContext) private var context
        @Environment(ProviderStore.self) private var providers
        @Environment(ChatEngine.self) private var engine
        @Query private var bots: [Bot]
        @Query private var crews: [Crew]

        private var sortedBots: [Bot] {
            bots.filter { $0.id != CaptainProfile.id }.sorted { lhs, rhs in
                // Pinned bots come first
                if lhs.isPinned != rhs.isPinned {
                    return lhs.isPinned && !rhs.isPinned
                }
                // Then sort by lastActivityAt descending
                return lhs.lastActivityAt > rhs.lastActivityAt
            }
        }

        private var sortedCrews: [Crew] {
            crews.sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned {
                    return lhs.isPinned && !rhs.isPinned
                }
                return lhs.lastActivityAt > rhs.lastActivityAt
            }
        }

        private var workingBotIDs: Set<UUID> {
            guard let id = engine.streamingBotID else { return [] }
            return [id]
        }

        @State private var captainChat: Bot?
        @State private var captainError: String?
        @State private var openCrew: Crew?
        @State private var search = ""
        @State private var showSettings = false
        @State private var showEditor = false
        @State private var editingBot: Bot?
        @State private var pendingDelete: Bot?
        @State private var showDeleteConfirm = false
        @State private var pendingDeleteCrew: Crew?
        @State private var showDeleteCrewConfirm = false

    private var filteredBots: [Bot] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return sortedBots }
        return sortedBots.filter {
            $0.name.lowercased().contains(q)
                || $0.role.lowercased().contains(q)
                || $0.systemPersonality.lowercased().contains(q)
        }
    }

    private var filteredCrews: [Crew] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return sortedCrews }
        return sortedCrews.filter {
            $0.name.lowercased().contains(q)
                || $0.mission.lowercased().contains(q)
        }
    }

    private var isEmpty: Bool {
        sortedBots.isEmpty && sortedCrews.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                captainCard
                if isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationDestination(item: $captainChat) { bot in
                ChatView(bot: bot)
            }
            .navigationDestination(item: $openCrew) { crew in
                CrewDetailView(crew: crew)
            }
            .alert("Couldn’t open Captain", isPresented: Binding(
                get: { captainError != nil },
                set: { if !$0 { captainError = nil } }
            )) {
                Button("OK", role: .cancel) { captainError = nil }
            } message: {
                Text(captainError ?? "")
            }
            .navigationTitle("BrainNotes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .searchable(text: $search, prompt: "Search bots and crews")
            .sheet(isPresented: $showSettings) {
                SettingsRootView()
            }
            .sheet(isPresented: $showEditor, onDismiss: { editingBot = nil }) {
                BotEditorView(bot: editingBot)
            }
            .confirmationDialog(
                pendingDelete.map { "Delete \($0.name)?" } ?? "Delete bot?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let b = pendingDelete { delete(b) }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("This permanently removes the bot and its entire chat history.")
            }
            .confirmationDialog(
                pendingDeleteCrew.map { "Disband \($0.name)?" } ?? "Disband crew?",
                isPresented: $showDeleteCrewConfirm,
                titleVisibility: .visible
            ) {
                Button("Disband", role: .destructive) {
                    if let c = pendingDeleteCrew { delete(c) }
                    pendingDeleteCrew = nil
                }
                Button("Cancel", role: .cancel) { pendingDeleteCrew = nil }
            } message: {
                Text("The crew and its shared history are removed. The specialists stay; they can join other crews.")
            }
        }
    }

    // MARK: - Subviews

    private var captainCard: some View {
        Button(action: openCaptain) {
            HStack(spacing: 12) {
                Image(systemName: "helm")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 48, height: 48)
                    .background(Theme.accent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("Captain").font(.headline)
                    Text("Chief of Staff").font(.subheadline)
                    Text("Plan your next outcome")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(16)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("captain-card")
        .padding(12)
    }

    private func openCaptain() {
        do {
            let captainID = CaptainProfile.id
            let descriptor = FetchDescriptor<Bot>(predicate: #Predicate { $0.id == captainID })
            if let existing = try context.fetch(descriptor).first {
                captainChat = existing
                return
            }
            let captain = CaptainProfile.makeBot()
            context.insert(captain)
            do {
                try context.save()
                captainChat = captain
            } catch {
                context.delete(captain)
                throw error
            }
        } catch {
            captainError = error.localizedDescription
        }
    }

    private var list: some View {
        List {
            if !providers.isConfigured {
                Section {
                    setupBanner
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            if !filteredCrews.isEmpty {
                Section {
                    crewRail
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } header: {
                    sectionHeader(title: "CREWS",
                                  count: filteredCrews.count,
                                  systemImage: "person.3.sequence.fill")
                }
            }

            Section {
                ForEach(filteredBots) { bot in
                    NavigationLink {
                        ChatView(bot: bot)
                    } label: {
                        BotRow(bot: bot)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12,
                                              bottom: 6, trailing: 12))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = bot
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            bot.isPinned.toggle()
                            try? context.save()
                        } label: {
                            Label(bot.isPinned ? "Unpin" : "Pin",
                                  systemImage: bot.isPinned ? "pin.slash" : "pin")
                        }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            editingBot = bot
                            showEditor = true
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            } header: {
                if !filteredCrews.isEmpty {
                    sectionHeader(title: "BOTS",
                                                count: filteredBots.count,
                                                systemImage: "bubble.left.and.bubble.right.fill")
                }
            }
        }
        .listStyle(.plain)
    }

    /// Horizontal rail of crew cards. Two cards per row on iPhone portrait
    /// thanks to the `CrewCard`'s 180 pt width and 16 pt outer padding.
    /// Each card is its own navigation destination so tapping straight into
    /// the crew detail is one gesture.
    private var crewRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(filteredCrews) { crew in
                    NavigationLink {
                        CrewDetailView(crew: crew)
                    } label: {
                        CrewCard(crew: crew, workingBotIDs: workingBotIDs)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        crewMenu(for: crew)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func crewMenu(for crew: Crew) -> some View {
        Button {
            crew.isPinned.toggle()
            try? context.save()
        } label: {
            Label(crew.isPinned ? "Unpin" : "Pin",
                  systemImage: crew.isPinned ? "pin.slash" : "pin")
        }
        Button(role: .destructive) {
            pendingDeleteCrew = crew
            showDeleteCrewConfirm = true
        } label: {
            Label("Disband", systemImage: "person.3.fill.xmark")
        }
    }

    private func sectionHeader(title: String,
                               count: Int,
                               systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(title) · \(count)")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .textCase(nil)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private var setupBanner: some View {
        Button {
            showSettings = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Theme.accent, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add your AI API key")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Bring your own OpenAI-compatible key to start chatting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No crews yet", systemImage: "person.3.sequence.fill")
        } description: {
            Text("Open Captain and ask for a team, or create a bot to start a private conversation.")
        } actions: {
            Button {
                openCaptain()
            } label: {
                Label("Talk to Captain", systemImage: "helm")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            Button {
                editingBot = nil
                showEditor = true
            } label: {
                Label("Create a bot", systemImage: "plus")
            }
            .buttonStyle(.bordered)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityIdentifier("settings-button")
            .accessibilityLabel("Settings")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                editingBot = nil
                showEditor = true
            } label: {
                Image(systemName: "plus.circle.fill")
            }
            .accessibilityLabel("New bot")
        }
    }

    private func delete(_ bot: Bot) {
        context.delete(bot)
        try? context.save()
    }

    private func delete(_ crew: Crew) {
        // Disbanding a crew removes the crew and its shared history but
        // keeps the specialists — they may belong to other crews.
        context.delete(crew)
        try? context.save()
    }
}

/// One chat-list row: avatar, name, last-message preview, timestamp, unread
/// count and pin marker.
struct BotRow: View {
    let bot: Bot

    var body: some View {
        HStack(spacing: 12) {
            BotAvatar(bot: bot)

            VStack(alignment: .leading, spacing: 3) {
                Text(bot.name)
                    .font(.system(size: 16.5, weight: .semibold))
                    .lineLimit(1)
                Text(preview)
                    .font(.system(size: 14.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 5) {
                Text(relativeTime)
                    .font(.system(size: 12))
                    .foregroundStyle(bot.unreadCount > 0 ? Theme.accent : .secondary)
                HStack(spacing: 5) {
                    if bot.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if bot.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if bot.unreadCount > 0 {
                        Text("\(bot.unreadCount)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.unreadBadge, in: Capsule())
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var preview: String {
        guard let last = bot.lastMessage else {
            if !bot.role.isEmpty { return bot.role }
            return bot.systemPersonality.isEmpty ? "Tap to start chatting" : bot.systemPersonality
        }
        // Markup is stripped so the row reads as prose rather than showing raw
        // `**` or link syntax. Memoised, because this runs per row per layout
        // pass and the strip is a full markdown parse.
        let body = MessagePreviewCache.shared.plain(from: last.text)
            .replacingOccurrences(of: "\n", with: " ")
        return last.isFromMe ? "You: \(body)" : body
    }

    private var relativeTime: String {
        let cal = Calendar.current
        let date = bot.lastActivityAt
        if cal.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 7 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}