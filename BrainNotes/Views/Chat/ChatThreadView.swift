import SwiftUI

/// The scrollable thread: rows, date separators, the streaming reply and the
/// scroll behaviour that keeps new content in view.
///
/// Row values are derived here rather than in the parent, so a message-set
/// change updates the rows and scrolls to the bottom in one place. `rows` is
/// built once per change — never per frame — which is what keeps scrolling
/// cheap on a long thread.
///
/// Scroll policy, in one place because every rule below exists to kill a seen
/// bug:
///
/// - **Own sends, stream start and stream end scroll unconditionally.** These
///   three moments are the conversational beat the user is watching; the
///   shared 100 ms throttle must never swallow them (it did, and the thread
///   sat off-screen showing wallpaper while the reply landed out of view).
/// - **Only the per-token follower is throttled and animated-scroll free.**
///   Animating `scrollTo` while the keyboard resizes the container produces a
///   stale target and overscrolls past the bottom anchor onto blank
///   wallpaper, so the forced scrolls run unanimated and a deferred settle
///   pass repairs whatever the layout pass moved.
struct ChatThreadView: View {
    let bot: Bot
    let engine: ChatEngine
    let isSelecting: Bool
    let selectedIDs: Set<UUID>
    /// Which row currently has its Delete action revealed.
    @Binding var openRow: UUID?

    var onDelete: (Message) -> Void
    var onReply: (Message) -> Void
    var onRegenerate: () -> Void
    var onToggleSelect: (Message) -> Void
    var onTapRow: () -> Void

    @State private var rows: [ChatRow]
    @State private var scrollState = ChatScrollState()

    init(bot: Bot,
         engine: ChatEngine,
         isSelecting: Bool,
         selectedIDs: Set<UUID>,
         openRow: Binding<UUID?>,
         onDelete: @escaping (Message) -> Void,
         onReply: @escaping (Message) -> Void,
         onRegenerate: @escaping () -> Void,
         onToggleSelect: @escaping (Message) -> Void,
         onTapRow: @escaping () -> Void) {
        self.bot = bot
        self.engine = engine
        self.isSelecting = isSelecting
        self.selectedIDs = selectedIDs
        self._openRow = openRow
        self.onDelete = onDelete
        self.onReply = onReply
        self.onRegenerate = onRegenerate
        self.onToggleSelect = onToggleSelect
        self.onTapRow = onTapRow
        // Built once here so the first frame already shows the thread instead of
        // popping in from empty.
        self._rows = State(initialValue: ChatRowBuilder.build(
            from: bot.sortedMessages,
            isStreaming: engine.isStreaming
        ))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: ChatLayout.rowSpacing) {
                    ForEach(rows) { row in
                        ChatRowView(
                            row: row,
                            isSelecting: isSelecting,
                            isSelected: selectedIDs.contains(row.id),
                            openRow: $openRow,
                            onDelete: { onDelete(row.message) },
                            onReply: { onReply(row.message) },
                            onRegenerate: onRegenerate,
                            onToggleSelect: { onToggleSelect(row.message) },
                            onTap: onTapRow
                        )
                        .id(row.id)
                    }

                    // The sentinel the thread scrolls to. It is also where the
                    // in-flight reply lives, isolated so a streamed token
                    // repaints only that bubble.
                    if isStreamingHere {
                        ChatStreamingBubble(bot: bot, engine: engine)
                            .id(ChatScrollState.bottomAnchor)
                    } else {
                        Color.clear
                            .frame(height: 1)
                            .id(ChatScrollState.bottomAnchor)
                    }

                    // Zero-height, and reads the stream itself, so following the
                    // stream does not make this body depend on `streamingText`.
                    StreamScrollFollower(engine: engine,
                                         proxy: proxy,
                                         state: scrollState)
                }
                .padding(.horizontal, ChatLayout.threadPaddingH)
                .padding(.vertical, ChatLayout.threadPaddingV)
            }
            .accessibilityIdentifier("chat-thread")
            // A tap anywhere on the thread — including the gaps between
            // bubbles, which belong to the scroll view, not the wallpaper —
            // puts the keyboard away, as a messenger does.
            .gesture(ThreadBackgroundTap { onTapRow() })
            // Open on the newest message, and stay there.
            .defaultScrollAnchor(.bottom)
            // `immediately` rather than `interactively`: any scroll closes the
            // keyboard, and it never steals the drag from the scroll view.
            .scrollDismissesKeyboard(.immediately)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height
                    - geometry.contentOffset.y
                    - geometry.containerSize.height < ChatLayout.pinnedThreshold
            } action: { _, pinned in
                // Deliberately not `@State`: this fires every scroll frame and
                // must not invalidate the view.
                scrollState.isPinnedToBottom = pinned
            }
            // The message set changed — a send, a reply, a delete. Reading the
            // count in the body is also what subscribes this view to the bot's
            // messages, so the change is delivered here rather than relying on
            // the stream having finished.
            .onChange(of: messageCount) { _, _ in
                // The user's own send always jumps to it — that is the one
                // scroll a messenger never negotiates. It also re-pins the
                // thread: if the keyboard's resize had flipped the pin false,
                // sending declares the intent to follow again.
                let ownSend = bot.sortedMessages.last?.isFromMe == true
                if ownSend { scrollState.isPinnedToBottom = true }
                rebuildRows()
                scrollToBottom(proxy, animated: !ownSend, force: ownSend)
            }
            .onChange(of: isStreamingHere) { wasStreaming, isNowStreaming in
                // The streaming bubble just appeared below the last row: bring
                // it into view at once, or the loading state sits off-screen
                // while the user wonders whether the send did anything.
                if isNowStreaming && !wasStreaming {
                    scrollState.isPinnedToBottom = true
                    scrollToBottom(proxy, animated: false, force: true)
                }
            }
            .onChange(of: engine.streamingBotID) { previous, current in
                // A reply that just finished in this thread lands as a new row;
                // another bot finishing must not move this scroll view.
                if previous == bot.id, current == nil {
                    rebuildRows()
                    // Forced and unthrottled: the token follower may have
                    // scrolled milliseconds ago, and dropping this scroll was
                    // what left finished replies invisible below the fold.
                    scrollToBottom(proxy, animated: false, force: true)
                    // The row swap happens in the same update as the height
                    // change; settle once more after layout so nothing is left
                    // half a bubble off the bottom edge.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        guard scrollState.isPinnedToBottom else { return }
                        proxy.scrollTo(ChatScrollState.bottomAnchor, anchor: .bottom)
                    }
                }
            }
            .onAppear { rebuildRows() }
        }
    }

    /// This bot's own reply is streaming.
    private var isStreamingHere: Bool {
        engine.isStreaming && engine.streamingBotID == bot.id
    }

    /// Read in the body so SwiftData reports relationship changes to this view.
    private var messageCount: Int { bot.messages.count }

    /// Recomputes the display rows in one pass over the sorted thread.
    private func rebuildRows() {
        rows = ChatRowBuilder.build(from: bot.sortedMessages,
                                   isStreaming: engine.isStreaming)
    }

    /// Scrolls to the newest content.
    ///
    /// A forced call ignores both the pin and the throttle: it is reserved for
    /// the conversational beats above, each of which fires at most once per
    /// message. Unforced calls — content arriving while the user reads back —
    /// still respect both.
    private func scrollToBottom(_ proxy: ScrollViewProxy,
                                animated: Bool,
                                force: Bool = false) {
        guard force || scrollState.isPinnedToBottom else { return }
        guard force || scrollState.mayScrollNow() else { return }

        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(ChatScrollState.bottomAnchor, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(ChatScrollState.bottomAnchor, anchor: .bottom)
        }
    }
}
