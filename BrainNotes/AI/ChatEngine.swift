import Foundation
import SwiftData
import SwiftUI

private extension String {
    /// `nil` when the string is empty or only whitespace, so callers can use
    /// `??` to fall through to a default.
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// Drives one bot's private thread: composes the prompt from the bot's persona
/// plus recent history, streams the reply, and persists both sides.
@MainActor
@Observable
final class ChatEngine {
    /// Text currently being streamed into the last bubble.
    var streamingText: String = ""
    var isStreaming: Bool = false
    /// Which bot the in-flight stream belongs to.
    ///
    /// One engine serves every chat, so without this a reply streaming in one
    /// bot rendered in whichever thread the user had open — the wrong bubble in
    /// the wrong conversation, and a "typing…" header on a bot that was idle.
    private(set) var streamingBotID: UUID?
    var errorMessage: String?
    /// Which bot the current error belongs to. Without this, a failure in one
    /// chat raised its alert — and offered Retry — in whichever thread the user
    /// had open next.
    private(set) var errorBotID: UUID?

    /// Live progress of the in-flight stream: who is answering, through which
    /// provider and model, which stage the reply is at, and how much has
    /// arrived. Cleared with the stream, so a progress card can never outlive
    /// the work it describes.
    private(set) var streamProgress: StreamProgress?

    /// Stages a reply moves through. Each transition reflects a real event —
    /// the HTTP response arriving, the first token landing — so the UI shows
    /// what is actually happening, not a scripted spinner.
    enum StreamStage: String, Equatable, Sendable {
        /// Prompt sent, waiting for the provider to open the stream.
        case connecting
        /// Provider answered; the model has not emitted a token yet.
        case thinking
        /// Tokens are arriving and being painted.
        case writing
        /// Stream closed; the reply is being validated and saved.
        case finishing

        /// Step number on the four-step track shown in the chat.
        var stepNumber: Int {
            switch self {
            case .connecting: return 1
            case .thinking: return 2
            case .writing: return 3
            case .finishing: return 4
            }
        }
    }

    struct StreamProgress: Equatable, Sendable {
        let botID: UUID
        let botName: String
        let model: String
        let providerLabel: String
        let startedAt: Date
        var stage: StreamStage
        var receivedCharacters: Int
        /// When the first token arrived; `nil` while still waiting.
        var firstTokenAt: Date?
    }

    private var streamTask: Task<Void, Never>?
    private let providers: ProviderStore
    private let webTools: WebToolStore

    /// Transport for the model calls. Production uses the shared session; tests
    /// inject a stubbed one so a whole reply — research round included — can be
    /// exercised in-process without a network.
    var session: URLSession = OpenAIClient.sharedSession

    /// Rounds of web research one reply may run before the model has to answer.
    /// Two covers both shapes: a single search or fetch, and Monid's
    /// discover-then-run ladder. Each round is a full model call, so the loop
    /// is bounded rather than trusting the model to stop.
    private static let webPassLimit = 2

    /// How many prior messages to replay as context. Chat apps show all history
    /// but sending all of it is wasteful; 40 turns is a safe default that keeps
    /// persona adherence without blowing the context window.
    private let contextWindow = 40

    init(providers: ProviderStore, webTools: WebToolStore = WebToolStore()) {
        self.providers = providers
        self.webTools = webTools
    }

    /// The web-tools prompt section for the providers currently on, or `nil`
    /// when none are — a bot is never told about tools it does not have.
    private var webAccessSection: String? {
        WebAccessPrompt.section(tinyfish: webTools.isActive(.tinyfish),
                                monid: webTools.isActive(.monid))
    }

    var canSend: Bool { providers.isConfigured }

    // MARK: - Sending

    func send(
        _ rawText: String,
        to bot: Bot,
        in context: ModelContext,
        image: MessageAttachment? = nil,
        replyTo: Message? = nil
    ) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        // An image alone is a valid turn, so only bail when there is neither.
        guard !text.isEmpty || image != nil, !isStreaming else { return }

        guard let provider = providers.active,
              !provider.baseURL.isEmpty else {
            report(AIError.notConfigured.errorDescription, for: bot)
            return
        }
        let key = providers.activeAPIKey ?? ""
        guard !key.isEmpty else {
            report(AIError.notConfigured.errorDescription, for: bot)
            return
        }

        // History must be read before inserting the new turn, otherwise the
        // outgoing message appears both in the replayed history and as the
        // pending user turn.
        let configuration = compileBotSystemPrompt(bot: bot,
                                                   webAccess: webAccessSection)
        let turns = await buildTurns(for: bot, systemPrompt: configuration.systemPrompt,
                                     pendingUser: text, image: image, replyTo: replyTo)

        let outgoing = Message(text: text, author: .me, delivery: .sending,
                               imageData: image?.data, imageName: image?.name,
                               replyToText: replyTo?.text ?? (replyTo?.hasImage == true ? "" : nil),
                               replyToAuthor: replyTo.map { $0.isFromMe ? "You" : bot.name },
                               replyToIsMine: replyTo?.isFromMe ?? false)
        outgoing.bot = bot
        context.insert(outgoing)
        bot.lastActivityAt = Date()
        try? context.save()

        streamingText = ""
        isStreaming = true
        streamingBotID = bot.id
        clearError()

        let model = bot.model.isEmpty ? provider.defaultModel : bot.model
        let temperature = configuration.temperature
        let client = OpenAIClient(baseURL: provider.baseURL, apiKey: key, session: session)

        streamProgress = StreamProgress(
            botID: bot.id, botName: bot.name, model: model,
            providerLabel: provider.label,
            startedAt: Date(), stage: .connecting,
            receivedCharacters: 0, firstTokenAt: nil)

        streamTask = Task { [weak self] in
            guard let self else { return }
            var text = ""
            var usage: OpenAIClient.TokenUsage?

            // The reply is built locally and inserted only when the stream
            // ends. Inserting it up front and assigning `text` per token
            // invalidated the whole message list on every token, which forced a
            // full chat re-render (and re-sort) dozens of times per second.
            let reply = Message(text: "", author: .bot, delivery: .sending)

            do {
                let first = try await self.streamRound(
                    client: client, model: model, turns: turns,
                    temperature: temperature, paintPrefix: "")
                text = first.text
                usage = first.usage

                // A user-initiated stop ends the stream *without* throwing, so
                // cancellation is checked explicitly. Persisting here would save
                // a truncated reply as if it were the model's finished answer.
                guard !Task.isCancelled else {
                    // The message really was sent; only the reply was stopped.
                    outgoing.delivery = .sent
                    try? context.save()
                    self.endStream()
                    return
                }
                guard !text.isEmpty else { throw AIError.empty }

                // A reply that asked for live data earns a research round: the
                // tools run, their results are fed back as a turn, and the model
                // answers for real. The block never survives into the bubble —
                // `researchPasses` strips it on every path out.
                let researched = try await self.researchPasses(
                    text: text, turns: turns, client: client,
                    model: model, temperature: temperature)
                text = researched.text
                if let reported = researched.usage { usage = reported }

                guard !Task.isCancelled else {
                    outgoing.delivery = .sent
                    try? context.save()
                    self.endStream()
                    return
                }
                guard !text.isEmpty else { throw AIError.empty }

                // Validation and persistence are the last real step, and the
                // progress card stays up through them — not a fake 100% beat.
                self.advanceProgress(to: .finishing, received: text.count)

                // One final paint so the last partial frame is never dropped.
                self.streamingText = text

                reply.text = text
                reply.delivery = .delivered
                reply.bot = bot
                context.insert(reply)
                persistUsage(usage, for: bot, model: model, provider: provider)
                outgoing.delivery = .read
                bot.lastActivityAt = Date()
                try? context.save()

                // Captain's structured actions are the only way its words
                // change the store: fenced action blocks are validated and
                // applied; prose without a block is a no-op. Invalid or
                // duplicate blocks surface as a chat error instead of silence.
                if bot.id == CaptainProfile.id {
                    let roster = (try? context.fetch(FetchDescriptor<Bot>())) ?? []
                    do {
                        _ = try ChatEngine.applyCaptainActions(
                            in: text, existingBots: roster, context: context)
                    } catch {
                        self.report(error.localizedDescription, for: bot)
                    }
                }
            } catch {
                guard !Task.isCancelled else {
                    outgoing.delivery = .sent
                    try? context.save()
                    self.endStream()
                    return
                }
                // A partial reply may still carry a tool block; strip it so no
                // failure path can show machine syntax to a reader.
                text = WebToolRequest.stripBlocks(text)
                if text.isEmpty {
                    // Nothing arrived: leave only the failed outgoing bubble.
                    outgoing.delivery = .failed
                } else {
                    // Keep the partial reply rather than discarding real output.
                    reply.text = text
                    reply.delivery = .delivered
                    reply.bot = bot
                    context.insert(reply)
                    outgoing.delivery = .read
                }
                outgoing.failureReason = error.localizedDescription
                self.report(error.localizedDescription, for: bot)
                bot.lastActivityAt = Date()
                try? context.save()
            }

            self.endStream()
        }
    }

    // MARK: - Streaming rounds

    /// One streaming round: runs the provider to natural end, paints the bubble
    /// as text arrives, and returns the accumulated text plus any usage report.
    ///
    /// `paintPrefix` is text from an earlier round of the same turn, so the
    /// bubble grows instead of flashing back to empty when a research round
    /// starts.
    private func streamRound(client: OpenAIClient,
                             model: String,
                             turns: [ChatTurn],
                             temperature: Double,
                             paintPrefix: String) async throws -> (text: String,
                                                                   usage: OpenAIClient.TokenUsage?) {
        var accumulated = ""
        var usage: OpenAIClient.TokenUsage?
        var lastPaint = CFAbsoluteTimeGetCurrent()

        for try await event in client.stream(model: model, turns: turns, temperature: temperature) {
            switch event {
            case .connected:
                self.advanceProgress(to: .thinking, received: 0)
            case .delta(let delta):
                accumulated += delta
                if self.streamProgress?.stage != .writing {
                    self.advanceProgress(to: .writing,
                                         received: accumulated.count,
                                         firstToken: true)
                }
            case .usage(let reported):
                usage = reported
            }

            // Coalesce token updates to ~30 Hz. Providers can emit far faster
            // than the display refreshes, and repainting per token was pure
            // waste. Usage events do not paint.
            guard case .delta = event else { continue }
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastPaint >= 0.033 {
                lastPaint = now
                self.streamingText = paintPrefix + accumulated
                self.advanceProgress(to: .writing, received: accumulated.count)
            }
        }
        return (accumulated, usage)
    }

    /// Runs the follow-up rounds a web tool block asks for.
    ///
    /// A bot that needs live data emits a `confabula-web` block; the operations
    /// run, their results are appended as a user turn, and the model's next
    /// output becomes the real answer. Bounded by `webPassLimit`, and a round
    /// whose tools produced nothing usable ends the loop — a failed lookup is
    /// answered once, not retried down the same broken path.
    private func researchPasses(text: String,
                                turns: [ChatTurn],
                                client: OpenAIClient,
                                model: String,
                                temperature: Double) async throws -> (text: String,
                                                                      usage: OpenAIClient.TokenUsage?) {
        guard webTools.anyActive else {
            // Providers are off: whatever block was emitted is still stripped,
            // so the bubble shows prose and the model's promise is just prose.
            return (WebToolRequest.stripBlocks(text), nil)
        }

        var text = text
        var usage: OpenAIClient.TokenUsage?
        var round = 0

        while round < Self.webPassLimit {
            try Task.checkCancellation()
            guard let call = WebToolRequest.parse(text),
                  !call.ops.isEmpty || !call.failures.isEmpty else { break }

            let outcome = await WebResearch(store: webTools).run(call)
            guard !outcome.modelText.isEmpty else { break }

            var followTurns = turns
            followTurns.append(ChatTurn(role: "assistant", content: text))
            followTurns.append(ChatTurn(role: "user", content: outcome.modelText))

            let prefix = call.prose.isEmpty ? "" : call.prose + "\n\n"
            let next = try await streamRound(client: client, model: model,
                                             turns: followTurns,
                                             temperature: temperature,
                                             paintPrefix: prefix)
            if let reported = next.usage { usage = reported }
            text = Self.join(prose: call.prose, continuation: next.text)
            round += 1

            if !outcome.producedData { break }
        }
        return (WebToolRequest.stripBlocks(text), usage)
    }

    /// The visible reply for a researched turn: the model's own preamble, then
    /// its grounded answer.
    private static func join(prose: String, continuation: String) -> String {
        let prose = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        let continuation = continuation.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (prose.isEmpty, continuation.isEmpty) {
        case (true, _):  return continuation
        case (_, true):  return prose
        default:         return prose + "\n\n" + continuation
        }
    }

    /// Stores the provider-reported usage for a completed reply. Records are
    /// anonymous (bot/model/provider snapshots only, never message text).
    private func persistUsage(
        _ usage: OpenAIClient.TokenUsage?, for bot: Bot,
        model: String, provider: ProviderConfig
    ) {
        guard let usage else { return } // no report: stay silent, never zero
        let record = AIRequestRecord(
            botID: bot.id, botName: bot.name,
            providerLabel: provider.label, providerBaseURL: provider.baseURL,
            model: model,
            promptTokens: usage.promptTokens,
            completionTokens: usage.completionTokens,
            totalTokens: usage.totalTokens)
        requestRecords.append(record)
    }

    /// Latest usage records first. In-memory for now; Phase 2b's dashboard
    /// reads from here and a later phase persists records with the store.
    private(set) var requestRecords: [AIRequestRecord] = []

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        endStream()
    }

    /// Clears the in-flight stream state. Every exit path of the stream task
    /// funnels through here, so `streamingBotID` can never outlive its stream
    /// and mislabel another chat as "typing".
    private func endStream() {
        isStreaming = false
        streamingText = ""
        streamingBotID = nil
        streamProgress = nil
    }

    /// Moves the progress card to a new stage. Mutations only ever happen here,
    /// so a stage can never regress mid-stream and the character count never
    /// shrinks.
    private func advanceProgress(to stage: StreamStage,
                                 received: Int,
                                 firstToken: Bool = false) {
        guard var progress = streamProgress else { return }
        if progress.stage.stepNumber < stage.stepNumber {
            progress.stage = stage
        }
        progress.receivedCharacters = max(progress.receivedCharacters, received)
        if firstToken, progress.firstTokenAt == nil {
            progress.firstTokenAt = Date()
        }
        streamProgress = progress
    }

    /// Records an error against the bot it happened in, and clears the previous
    /// one. Takes an optional message because `LocalizedError.errorDescription`
    /// is optional, even for cases that always define one.
    private func report(_ message: String?, for bot: Bot) {
        errorMessage = message ?? "Something went wrong."
        errorBotID = bot.id
    }

    /// Dismisses the current error. Called by the chat that owns it.
    func clearError() {
        errorMessage = nil
        errorBotID = nil
    }

    /// Whether the given bot is the one the current error belongs to.
    func hasError(for bot: Bot) -> Bool {
        errorMessage != nil && errorBotID == bot.id
    }

    // MARK: - Prompt assembly

    private func buildTurns(
        for bot: Bot, systemPrompt: String, pendingUser: String,
        image: MessageAttachment? = nil, replyTo: Message? = nil
    ) async -> [ChatTurn] {
        var turns: [ChatTurn] = [ChatTurn(role: "system", content: systemPrompt)]

        // The new user turn is appended explicitly below, so history here is
        // everything already persisted.
        let history = bot.sortedMessages.filter { !$0.isEmpty }
        let recent = history.suffix(contextWindow)

        for m in recent {
            // Base64 encoding is expensive; do it off the main actor so the
            // composer's send path never blocks the UI thread.
            let imageData = m.imageData
            let dataURL: String? = await Task.detached(priority: .userInitiated) {
                guard let imageData, !imageData.isEmpty else { return nil }
                let mime = MessageAttachment.mimeType(for: imageData) ?? "image/jpeg"
                return "data:\(mime);base64,\(imageData.base64EncodedString())"
            }.value
            turns.append(ChatTurn(
                role: m.isFromMe ? "user" : "assistant",
                content: m.text,
                imageDataURL: dataURL
            ))
        }

        // Quote the referenced message inline so the model knows what "this"
        // refers to. Kept as plain text so every provider understands it.
        var userContent = pendingUser
        if let replyTo, let quote = replyTo.text.nilIfBlank ?? (replyTo.hasImage ? "(photo)" : nil) {
            let who = replyTo.isFromMe ? "the user" : bot.name
            let label = userContent.isEmpty ? "Referring to this:" : userContent
            userContent = "Regarding this message from \(who): \"\(quote)\"\n\n\(label)"
        }
        let dataURL = await Task.detached(priority: .userInitiated) {
            image?.dataURL
        }.value
        turns.append(ChatTurn(
            role: "user",
            content: userContent,
            imageDataURL: dataURL
        ))

        // Providers require the first non-system turn to be from the user.
        if turns.count > 1, turns[1].role == "assistant" {
            turns.insert(ChatTurn(role: "user", content: "(continuing our chat)"),
                         at: 1)
        }
        return turns
    }

    /// Re-runs the last exchange for a different answer, keeping the user's
    /// message and discarding the previous reply.
    func regenerate(for bot: Bot, in context: ModelContext) async {
        guard !isStreaming else { return }
        // Checked before anything is deleted: a regenerate that cannot start
        // must leave the thread exactly as it was.
        guard canStartStream else {
            report(AIError.notConfigured.errorDescription, for: bot)
            return
        }

        // The prompt to re-answer is the last user turn.
        let ordered = bot.sortedMessages
        guard let lastUser = ordered.last(where: { $0.isFromMe && !$0.isEmpty })
        else { return }

        // Drop everything after that prompt (the old reply), then resend.
        let trailing = ordered.filter { $0.timestamp > lastUser.timestamp }
        for m in trailing { context.delete(m) }
        try? context.save()

        let prompt = lastUser.text
        let image = lastUser.imageData.flatMap { data in
            MessageAttachment(data: data, name: lastUser.imageName ?? "photo.jpg")
        }
        context.delete(lastUser)
        try? context.save()

        clearError()
        await send(prompt, to: bot, in: context, image: image)
    }

    /// Whether a send can actually start: a provider with a key must be
    /// configured, and no other stream may be in flight. Consulted before any
    /// destructive step, so a regenerate or retry can never delete a message it
    /// then fails to replace.
    private var canStartStream: Bool {
        guard !isStreaming,
              let provider = providers.active,
              !provider.baseURL.isEmpty
        else { return false }
        return !(providers.activeAPIKey ?? "").isEmpty
    }

    // MARK: - Attachments

    /// Resolves whether a specific model accepts images, using the shared model
    /// catalog when the provider publishes capabilities and the name heuristic
    /// otherwise.
    func visionSupport(for modelID: String) -> VisionSupport {
        providers.catalog.support(for: modelID, provider: providers.active)
    }

    /// The model this bot will actually use, falling back to the provider
    /// default when the bot has no override.
    func effectiveModel(for bot: Bot?) -> String {
        let explicit = bot?.model.trimmingCharacters(in: .whitespaces) ?? ""
        if !explicit.isEmpty { return explicit }
        return providers.active?.defaultModel ?? ""
    }

    /// Whether the composer's attach button should be enabled for this bot.
    var canAttachImagesForActiveModel: Bool {
        visionSupport(for: effectiveModel(for: nil)).allowsImages
    }

    // MARK: - Retry

    func retryLastFailure(for bot: Bot, in context: ModelContext) async {
        guard !isStreaming else { return }
        guard let failed = bot.sortedMessages.last(where: { $0.delivery == .failed })
        else { return }
        // Same rule as regenerate: never delete what cannot be re-sent.
        guard canStartStream else {
            report(AIError.notConfigured.errorDescription, for: bot)
            return
        }
        let text = failed.text
        // Drop the failed turn and everything after it, identified by order in
        // the thread rather than by timestamp — two messages can share a stamp,
        // and a timestamp filter silently took unrelated messages with it.
        let ordered = bot.sortedMessages
        guard let failedIndex = ordered.firstIndex(where: { $0.id == failed.id })
        else { return }
        for m in ordered[failedIndex...] { context.delete(m) }
        try? context.save()
        bot.invalidateOrderCache()
        clearError()
        await send(text, to: bot, in: context)
    }

    // MARK: - Captain actions

    /// Extracts, validates, and applies Captain's fenced action blocks from a
    /// finished reply. This is the single execution path from Captain's words
    /// to the store — no other pathway exists, and any failure throws before
    /// the store is touched.
    static func applyCaptainActions(
        in reply: String,
        existingBots: [Bot],
        context: ModelContext
    ) throws -> [String] {
        guard let envelope = CaptainAction.envelope(in: reply) else { return [] }
        guard let data = envelope.data(using: .utf8) else { return [] }
        let actions = try CaptainAction.decode(from: data).get()
        return try CaptainActionProcessor.apply(
            actions, in: context, existingBots: existingBots).applied
    }
}
