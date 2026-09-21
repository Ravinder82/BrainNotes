import SwiftUI
import SwiftData
import VisionKit

/// A bot's private conversation: a messenger thread with a wallpaper, date
/// separators, streaming replies and a pinned composer.
///
/// This view owns the screen's state and its side effects. Everything it draws
/// is delegated: the thread to `ChatThreadView`, the bar to
/// `ChatComposerView`, the title to `ChatHeaderView`.
struct ChatView: View {
    @Bindable var bot: Bot

    @Environment(\.modelContext) private var context
    @Environment(ProviderStore.self) private var providers
    @Environment(ChatEngine.self) private var engine
    @Environment(\.colorScheme) private var scheme

    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    @State private var showBotInfo = false
    @State private var showEditor = false

    /// Which row currently has its Delete action revealed.
    @State private var openMessageRow: UUID?
    /// Message being quoted by the current reply.
    @State private var replyTarget: Message?
    /// Photo staged for the next send.
    @State private var pendingAttachment: MessageAttachment?

    @State private var showPhotoPicker = false
    @State private var showPhotoPickerForBackgroundRemoval = false
    @State private var showDocumentScanner = false
    @State private var showVisionWarning = false

    /// Every bot, so Captain's crew surfaces can resolve specialists by name
    /// without each card running its own query.
    @Query private var allBots: [Bot]

    /// Multi-select: tap messages to pick them, then export or delete.
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var showBulkDeleteConfirm = false

    @State private var exportItems: [Any] = []
    @State private var showExportSheet = false

    /// Guards the one-time work of the first appearance.
    @State private var didAppear = false

    private var messages: [Message] { bot.sortedMessages }

    var body: some View {
        ZStack {
            wallpaper
            VStack(spacing: 0) {
                // Mission control: Captain's chat carries the crew deck with a
                // live status ring per specialist.
                if bot.id == CaptainProfile.id {
                    CrewDeckView(engine: engine)
                }
                ChatThreadView(
                    bot: bot,
                    engine: engine,
                    isSelecting: isSelecting,
                    selectedIDs: selectedIDs,
                    openRow: $openMessageRow,
                    onDelete: deleteMessage,
                    onReply: beginReply,
                    onRegenerate: regenerate,
                    onToggleSelect: toggleSelection,
                    onTapRow: dismissKeyboard
                )
                if !isSelecting {
                    composer
                }
            }
        }
        .environment(\.crewLookup, CrewLookupBox(byName: crewLookup))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(isPresented: $showBotInfo) {
            BotInfoView(bot: bot)
        }
        .sheet(isPresented: $showEditor) {
            BotEditorView(bot: bot)
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPicker { attachment in
                stage(attachment)
            }
        }
        .sheet(isPresented: $showPhotoPickerForBackgroundRemoval) {
            PhotoPicker { attachment in
                stageRemovingBackground(from: attachment)
            }
        }
        .sheet(isPresented: $showDocumentScanner) {
            DocumentScannerPresenter(isPresented: $showDocumentScanner) { scan in
                handleScannedDocument(scan)
            }
        }
        .sheet(isPresented: $showExportSheet) {
            ShareSheet(items: exportItems)
        }
        .alert("This model can't read images",
               isPresented: $showVisionWarning) {
            Button("Send anyway") { performSend() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(engine.effectiveModel(for: bot)) is listed as text-only by "
                 + "your provider, so the photo will likely be ignored. Send "
                 + "anyway, or switch this bot to a vision model in its "
                 + "settings.")
        }
        .alert("Couldn't get a reply",
               isPresented: Binding(
                   // Scoped to this bot: the engine is shared, so an error from
                   // another thread must not raise its alert here.
                   get: { engine.hasError(for: bot) },
                   set: { if !$0 { engine.clearError() } }
               )) {
            Button("Retry") {
                Task { await engine.retryLastFailure(for: bot, in: context) }
            }
            Button("Dismiss", role: .cancel) { engine.clearError() }
        } message: {
            Text(engine.errorMessage ?? "")
        }
        .confirmationDialog(
            "Delete \(selectedIDs.count) message\(selectedIDs.count == 1 ? "" : "s")?",
            isPresented: $showBulkDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteSelection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the selected messages from this chat.")
        }
        .onAppear { handleAppear() }
        .onDisappear { markRead() }
    }

    // MARK: - Chrome

    /// Lowercased-name → bot map backing the crew manifest card's links.
    private var crewLookup: [String: Bot] {
        Dictionary(uniqueKeysWithValues: allBots.map {
            ($0.name.lowercased(), $0)
        })
    }

    /// The thread's wallpaper. Sits behind everything and swallows taps that
    /// miss a bubble — tapping empty space puts the keyboard away, as it does in
    /// a messenger. (The scroll view carries its own handler for the region it
    /// covers; this catches whatever is left.)
    private var wallpaper: some View {
        Theme.chatBackground(scheme)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { dismissKeyboard() }
    }

    private var composer: some View {
        ChatComposerView(
            draft: $draft,
            focus: $inputFocused,
            bot: bot,
            replyTarget: replyTarget,
            attachment: pendingAttachment,
            isStreamingHere: isStreamingHere,
            isStreamingElsewhere: isStreamingElsewhere,
            canAttach: attachEnabled,
            onSend: sendDraft,
            onStop: { engine.cancel() },
            onCancelReply: { withAnimation(.easeOut(duration: 0.18)) { replyTarget = nil } },
            onRemoveAttachment: { withAnimation(.easeOut(duration: 0.18)) { pendingAttachment = nil } },
            onPickPhoto: { showPhotoPicker = true },
            onScanDocument: { showDocumentScanner = true },
            onRemoveBackground: { showPhotoPickerForBackgroundRemoval = true }
        )
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isSelecting {
            ChatSelectionToolbar(
                count: selectedIDs.count,
                onCancel: exitSelection,
                onExport: exportSelection,
                onDelete: { showBulkDeleteConfirm = true }
            )
        } else {
            ToolbarItem(placement: .principal) {
                ChatHeaderView(
                    bot: bot,
                    isTyping: isStreamingHere,
                    statusText: isStreamingHere
                        ? ChatHeaderView.statusText(for: engine.streamProgress)
                        : nil
                ) {
                    showBotInfo = true
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                conversationMenu
            }
        }
    }

    private var conversationMenu: some View {
        Menu {
            Button {
                showBotInfo = true
            } label: {
                Label("Bot info", systemImage: "info.circle")
            }
            Button {
                showEditor = true
            } label: {
                Label("Edit personality", systemImage: "slider.horizontal.3")
            }
            Button {
                enterSelection()
            } label: {
                Label("Select messages", systemImage: "checkmark.circle")
            }
            Toggle(isOn: $bot.isMuted) {
                Label(bot.isMuted ? "Unmute" : "Mute",
                      systemImage: bot.isMuted ? "bell" : "bell.slash")
            }
            Toggle(isOn: $bot.isPinned) {
                Label(bot.isPinned ? "Unpin" : "Pin", systemImage: "pin")
            }
            Divider()
            Button(role: .destructive) {
                clearHistory()
            } label: {
                Label("Clear chat", systemImage: "eraser")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityIdentifier("conversation-menu")
        .accessibilityLabel(Text("Conversation options"))
    }

    // MARK: - Streaming state

    /// True while this chat's own reply is streaming. The engine is shared by
    /// every bot, so the plain `isStreaming` flag is not enough to decide what
    /// belongs on screen here.
    private var isStreamingHere: Bool {
        engine.isStreaming && engine.streamingBotID == bot.id
    }

    /// True while a different bot's reply is streaming, during which this
    /// composer must not offer to send or to stop the other thread.
    private var isStreamingElsewhere: Bool {
        engine.isStreaming && !isStreamingHere
    }

    /// The attach button is enabled only when the model this bot will use is
    /// known to accept images (or nothing is known either way).
    private var attachEnabled: Bool {
        engine.visionSupport(for: engine.effectiveModel(for: bot)).allowsImages
    }

    // MARK: - Lifecycle

    private func handleAppear() {
        markRead()
        guard !didAppear else { return }
        didAppear = true
        // Learn which models this provider offers, so the attach button can
        // reflect real image support instead of guessing from the name.
        Task {
            await providers.catalog.refresh(provider: providers.active,
                                            apiKey: providers.activeAPIKey ?? "")
        }
    }

    private func markRead() {
        guard bot.unreadCount != 0 else { return }
        bot.unreadCount = 0
        try? context.save()
    }

    private func dismissKeyboard() {
        // Only the composer loses focus; a message may own a text selection.
        inputFocused = false
    }

    // MARK: - Sending

    private func sendDraft() {
        // If a photo is staged and the model isn't known to take images, warn
        // rather than silently dropping it.
        if pendingAttachment != nil, !attachEnabled {
            showVisionWarning = true
            return
        }
        performSend()
    }

    private func performSend() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || pendingAttachment != nil else { return }

        let attachment = pendingAttachment
        let quoted = replyTarget
        draft = ""
        withAnimation(.easeOut(duration: 0.18)) {
            pendingAttachment = nil
            replyTarget = nil
        }

        Task {
            await engine.send(text, to: bot, in: context,
                              image: attachment, replyTo: quoted)
        }
    }

    private func beginReply(to message: Message) {
        withAnimation(.easeOut(duration: 0.18)) { replyTarget = message }
        inputFocused = true
    }

    private func regenerate() {
        Task { await engine.regenerate(for: bot, in: context) }
    }

    // MARK: - Attachments

    private func stage(_ attachment: MessageAttachment) {
        withAnimation(.easeOut(duration: 0.2)) { pendingAttachment = attachment }
    }

    /// Offers background removal, falling back to the original photo when the
    /// subject can't be isolated.
    private func stageRemovingBackground(from attachment: MessageAttachment) {
        Task {
            let processed = try? await attachment.removingBackground()
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) {
                    pendingAttachment = processed ?? attachment
                }
            }
        }
    }

    private func handleScannedDocument(_ scan: VNDocumentCameraScan) {
        guard let attachment = scan.firstPageAttachment() else { return }
        stage(attachment)

        // `VNDocumentCameraScan` is not Sendable, so copy the pages out as
        // `Data` before leaving the main actor and OCR those instead.
        let pageData: [Data] = (0..<scan.pageCount).compactMap {
            scan.imageOfPage(at: $0).jpegData(compressionQuality: 0.9)
        }

        Task {
            var fullText = ""
            for data in pageData {
                guard let image = UIImage(data: data) else { continue }
                if let page = try? await image.ocrText() {
                    fullText += page + "\n\n"
                }
            }
            let text = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { draft = text }
        }
    }

    // MARK: - Deleting

    private func clearHistory() {
        for message in bot.messages { context.delete(message) }
        bot.messages = []
        bot.invalidateOrderCache()
        bot.lastActivityAt = Date()
        try? context.save()
    }

    /// Deletes one message and keeps the bot's activity stamp consistent with
    /// whatever remains in the thread.
    private func deleteMessage(_ message: Message) {
        context.delete(message)
        bot.messages.removeAll { $0.id == message.id }
        bot.invalidateOrderCache()
        if let latest = bot.sortedMessages.last {
            bot.lastActivityAt = latest.timestamp
        }
        try? context.save()
    }

    // MARK: - Multi-select

    private func enterSelection() {
        withAnimation(.easeOut(duration: 0.18)) {
            isSelecting = true
            selectedIDs = []
        }
    }

    private func exitSelection() {
        withAnimation(.easeOut(duration: 0.18)) {
            isSelecting = false
            selectedIDs = []
        }
    }

    private func toggleSelection(_ message: Message) {
        if selectedIDs.contains(message.id) {
            selectedIDs.remove(message.id)
        } else {
            selectedIDs.insert(message.id)
        }
    }

    private func deleteSelection() {
        let doomed = messages.filter { selectedIDs.contains($0.id) }
        guard !doomed.isEmpty else { return }
        for message in doomed { context.delete(message) }
        bot.messages.removeAll { selectedIDs.contains($0.id) }
        bot.invalidateOrderCache()
        if let latest = bot.sortedMessages.last {
            bot.lastActivityAt = latest.timestamp
        }
        try? context.save()
        exitSelection()
    }

    private func exportSelection() {
        let chosen = messages
            .filter { selectedIDs.contains($0.id) }
            .sorted { $0.timestamp < $1.timestamp }
        guard !chosen.isEmpty else { return }
        exportItems = [ChatExporter.plainText(messages: chosen, botName: bot.name)]
        showExportSheet = true
    }
}