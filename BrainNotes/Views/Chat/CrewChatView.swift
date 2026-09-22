import SwiftUI
import SwiftData

/// A crew's shared group chat — what opens when you tap a crew card on the
/// dashboard. The user types one prompt; the engine picks a lead specialist
/// (the first idle member, falling back to the first), streams their answer
/// into the same shared thread, and persists both turns with `crew == crew`
/// so the conversation survives a relaunch.
///
/// The screen deliberately reuses the per-bot chat row, composer and bubble
/// surfaces — Captain's design rule is that "a conversation is a conversation,
/// whether it is with one specialist or a team", and re-using those pieces
/// keeps scroll, selection and delivery semantics identical.
///
/// What's different from `ChatView`:
///
///  - The header carries the crew's mission instead of a bot's role.
///  - The composer dispatches to `engine.send(_:in:)` not `engine.send(_:to:)`.
///  - The streaming bubble uses the lead specialist's avatar, so the user can
///    see *who* on the crew is currently answering.
///  - There is no per-member 1:1 deep-link here — the crew itself is the unit
///    of work. The crew detail screen is still reachable from the header menu
///    for members who want to chat with a single specialist in private.
struct CrewChatView: View {
    @Bindable var crew: Crew

    @Environment(\.modelContext) private var context
    @Environment(ProviderStore.self) private var providers
    @Environment(ChatEngine.self) private var engine
    @Environment(\.colorScheme) private var scheme

    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    @State private var showCrewInfo = false
    /// Crews are managed from the captain footer; the dashboard isn't shown here.
    @State private var showCaptain = false

    /// Row-level selection for bulk actions. Same UX as `ChatView`.
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []

    private var messages: [Message] { crew.sortedMessages }
    private var workingBotID: UUID? { engine.streamingBotID }
    private var workingLead: Bot? {
        guard let id = workingBotID else { return nil }
        return crew.orderedMembers.first(where: { $0.id == id })
    }
    private var isStreamingHere: Bool { workingLead != nil }

    var body: some View {
        ZStack {
            wallpaper
            VStack(spacing: 0) {
                thread
                if !isSelecting {
                    composer
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(isPresented: $showCrewInfo) {
            CrewDetailView(crew: crew)
        }
        .alert("Crew chat could not start",
               isPresented: Binding(
                get: { engine.hasError(for: crew) },
                set: { if !$0 { engine.clearError() } })) {
            Button("OK", role: .cancel) { engine.clearError() }
        } message: {
            Text(engine.errorMessage ?? "")
        }
    }

    // MARK: - Thread

    /// The scrollable thread. Built from the crew's shared message list and
    /// shows the lead's in-flight reply as a live streaming bubble.
    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: ChatLayout.rowSpacing) {
                    if messages.isEmpty {
                        emptyHint
                    }
                    ForEach(buildRows()) { row in
                        ChatRowView(
                            row: row,
                            isSelecting: isSelecting,
                            isSelected: selectedIDs.contains(row.id),
                            openRow: .constant(nil),
                            onDelete: { delete(row.message) },
                            onReply: {},
                            onRegenerate: {},
                            onToggleSelect: { toggleSelection(row.message) },
                            onTap: { inputFocused = false }
                        )
                        .id(row.id)
                    }
                    if let lead = workingLead, !engine.streamingText.isEmpty {
                        streamingRow(for: lead)
                            .id("streaming")
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.vertical, ChatLayout.rowSpacing)
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private func streamingRow(for lead: Bot) -> some View {
        // `ChatStreamingBubble` takes a `Bot`, which the lead specialist
        // is — the streaming surface is identical to a private 1:1, only
        // the engine key is the crew instead of the bot.
        ChatStreamingBubble(bot: lead, engine: engine)
            .padding(.horizontal, ChatLayout.composerPaddingH)
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.3.sequence.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Color(hex: crew.accentColorHex))
            Text("Start the crew's work")
                .font(.subheadline.weight(.semibold))
            Text("Type the first task — Captain's lead specialist will reply here, and every specialist can read the thread.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Composer

    private var composer: some View {
        CrewComposerView(
            draft: $draft,
            focus: $inputFocused,
            isStreamingHere: isStreamingHere,
            isStreamingElsewhere: engine.isStreaming && !isStreamingHere,
            canSend: !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            onSend: performSend,
            onStop: { engine.cancel() })
    }

    private func performSend() {
        let text = draft
        draft = ""
        inputFocused = false
        Task {
            await engine.send(text, to: crew, in: context)
        }
    }

    // MARK: - Rows

    /// Builds the same `ChatRow` shape `ChatView` uses, but reads the crew's
    /// shared message list. Kept inline because the bookkeeping (date
    /// separators, tail flags, canRegenerate) is identical to ChatRowBuilder
    /// but the input set is the crew's `sortedMessages` rather than a bot's.
    private func buildRows() -> [ChatRow] {
        let source = messages
        var rows: [ChatRow] = []
        var previousAuthor: MessageAuthor?
        var previousDate: Date?
        for message in source where !message.isEmpty {
            let sameAuthor = previousAuthor == message.author
            let showTail = !sameAuthor
            let cal = Calendar.current
            let showsDateSeparator: Bool
            let dateText: String
            if let previousDate, cal.isDate(previousDate, inSameDayAs: message.timestamp) {
                showsDateSeparator = false
                dateText = ""
            } else {
                showsDateSeparator = true
                dateText = ChatFormatters.dateOnlyString(for: message.timestamp)
            }
            rows.append(ChatRow(
                message: message,
                showTail: showTail,
                showsDateSeparator: showsDateSeparator,
                dateSeparatorText: dateText,
                timeText: ChatFormatters.timeString(for: message.timestamp),
                canRegenerate: false))
            previousAuthor = message.author
            previousDate = message.timestamp
        }
        return rows
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Button {
                showCrewInfo = true
            } label: {
                HStack(spacing: 8) {
                    CrewAvatarChip(crew: crew, working: isStreamingHere)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(crew.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(isStreamingHere
                             ? "\(workingLead?.name ?? "Lead") is replying…"
                             : "\(crew.orderedMembers.count) specialists · \(crew.mission)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("crew-chat-title")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    showCrewInfo = true
                } label: {
                    Label("Crew details", systemImage: "person.2.crop.square")
                }
                Button {
                    isSelecting.toggle()
                    if !isSelecting { selectedIDs.removeAll() }
                } label: {
                    Label(isSelecting ? "Done selecting" : "Select messages",
                          systemImage: "checkmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Crew chat options")
        }
    }

    // MARK: - Wallpaper

    private var wallpaper: some View {
        Theme.chatBackground(scheme).ignoresSafeArea()
    }

    // MARK: - Actions

    private func delete(_ message: Message) {
        context.delete(message)
        try? context.save()
        crew.invalidateOrderCache()
    }

    private func toggleSelection(_ message: Message) {
        if selectedIDs.contains(message.id) {
            selectedIDs.remove(message.id)
        } else {
            selectedIDs.insert(message.id)
        }
    }
}

// MARK: - Composer

/// The pinned composer for a crew group chat — text field + send button.
///
/// Attachment / quote / scan are deliberately not surfaced here: this is the
/// "drive the crew" surface, not the "share a photo with one specialist"
/// surface. The user who needs to attach can drop into the crew detail screen
/// and pick a member for a private 1:1.
private struct CrewComposerView: View {
    @Binding var draft: String
    let focus: FocusState<Bool>.Binding
    let isStreamingHere: Bool
    let isStreamingElsewhere: Bool
    let canSend: Bool

    var onSend: () -> Void
    var onStop: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Send to the crew", text: $draft, axis: .vertical)
                    .lineLimit(ChatLayout.composerLineLimit)
                    .padding(.horizontal, ChatLayout.composerFieldPaddingH)
                    .padding(.vertical, ChatLayout.composerFieldPaddingV)
                    .background(Theme.composerField(scheme),
                                in: RoundedRectangle(cornerRadius: ChatLayout.composerFieldCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: ChatLayout.composerFieldCornerRadius)
                            .stroke(Theme.hairline(scheme), lineWidth: 1)
                    )
                    .focused(focus)
                    .accessibilityIdentifier("crew-message-field")
                    .accessibilityLabel(Text("Message the crew"))
                Button {
                    if isStreamingHere { onStop() } else { onSend() }
                } label: {
                    let enabled = isStreamingHere || (canSend && !isStreamingElsewhere)
                    ZStack {
                        Circle()
                            .fill(enabled ? Theme.accentDeep : Theme.quietDisc(scheme))
                        Circle()
                            .strokeBorder(enabled ? Color.clear : Theme.hairline(scheme),
                                          lineWidth: 1)
                        Image(systemName: isStreamingHere ? "stop.fill" : "arrow.up")
                            .font(.system(size: isStreamingHere ? 12 : 16, weight: .bold))
                            .foregroundStyle(enabled ? Color.white
                                             : Color.secondary.opacity(0.55))
                    }
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
                }
                .disabled(isStreamingHere ? false : (!canSend || isStreamingElsewhere))
                .accessibilityIdentifier("crew-send-button")
                .accessibilityLabel(Text(isStreamingHere ? "Stop" : "Send to crew"))
            }
            .padding(.horizontal, ChatLayout.composerPaddingH)
            .padding(.vertical, ChatLayout.composerPaddingV)
            .background(Theme.bar(scheme))
        }
    }
}

// MARK: - Title chip

private struct CrewAvatarChip: View {
    let crew: Crew
    let working: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(
                    colors: [tint.opacity(0.95), tint.opacity(0.65)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing))
                .frame(width: 30, height: 30)
            Text(crew.emoji)
                .font(.system(size: 16))
        }
        .overlay(alignment: .bottomTrailing) {
            if working {
                Circle()
                    .fill(Theme.live)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.2))
                    .offset(x: 1, y: 1)
            }
        }
    }

    private var tint: Color { Color(hex: crew.accentColorHex) }
}
