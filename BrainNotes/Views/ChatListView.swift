import SwiftUI
import SwiftData

/// The main screen: a searchable list of crew group chats plus a Captain
/// card for management.
///
/// The dashboard no longer surfaces individual bots — Captain owns the roster
/// and only emits operators as members of a crew, so a specialist always
/// belongs to a team. Tapping a crew card opens the shared group chat; the
/// roster view (`CrewDetailView`) is reachable from the card's context menu
/// for the user who wants to read each member's role before driving them.
struct ChatListView: View {
        @Environment(\.modelContext) private var context
        @Environment(ProviderStore.self) private var providers
        @Environment(ChatEngine.self) private var engine
        @Query private var crews: [Crew]

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
        @State private var pendingDeleteCrew: Crew?
        @State private var showDeleteCrewConfirm = false

        private var filteredCrews: [Crew] {
            let q = search.trimmingCharacters(in: .whitespaces).lowercased()
            guard !q.isEmpty else { return sortedCrews }
            return sortedCrews.filter {
                $0.name.lowercased().contains(q)
                    || $0.mission.lowercased().contains(q)
            }
        }

        private var isEmpty: Bool {
            sortedCrews.isEmpty
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
                CrewChatView(crew: crew)
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
            .searchable(text: $search, prompt: "Search crews")
            .sheet(isPresented: $showSettings) {
                SettingsRootView()
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
        }
        .listStyle(.plain)
    }

    /// Horizontal rail of crew cards. Tapping a card opens the crew's shared
    /// group chat — Captain's primary unit of work is the crew, so the
    /// dashboard jump straight into the surface where the work actually
    /// happens. The detail screen is reachable from the card's context menu.
    private var crewRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(filteredCrews) { crew in
                    NavigationLink {
                        CrewChatView(crew: crew)
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
        NavigationLink {
            CrewDetailView(crew: crew)
        } label: {
            Label("Crew details", systemImage: "person.2.crop.square")
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
            Text("Open Captain and tell him the outcome you need. He'll assemble a crew you can work with.")
        } actions: {
            Button {
                openCaptain()
            } label: {
                Label("Talk to Captain", systemImage: "helm")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
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
    }

    private func delete(_ crew: Crew) {
        // Disbanding a crew removes the crew and its shared history but
        // keeps the specialists — they may belong to other crews.
        context.delete(crew)
        try? context.save()
    }
}