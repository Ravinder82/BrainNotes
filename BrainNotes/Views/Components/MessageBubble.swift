import SwiftUI
import UIKit

/// One message, drawn as a bubble.
///
/// Layout rules, in the order they matter:
///
/// - Outgoing messages sit right, incoming left, with a guaranteed gap on the
///   far side so the tail side is always obvious.
/// - A bubble hugs its content and never exceeds its share of the screen width.
/// - The body is one selectable text document: the reader can select any span —
///   across paragraphs, list items and code — with the native handles and copy
///   it, exactly like any first-class iOS text. Message actions live on a
///   trailing "⋯" button, because a context menu over selectable text claims
///   the long-press that selection needs.
struct MessageBubble: View {
    let message: Message
    /// Only the last message of a same-sender run carries the tail.
    let showTail: Bool
    /// Preformatted by `ChatRowBuilder`, so no date formatter runs in layout.
    var timeText: String?
    var onReply: (() -> Void)?
    var onDelete: (() -> Void)?
    var onRegenerate: (() -> Void)?
    /// True only for the newest bot reply, the only one worth re-running.
    var canRegenerate: Bool = false

    @Environment(\.colorScheme) private var scheme
    @State private var showInfo = false
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false

    private var isOutgoing: Bool { message.isFromMe }
    private var maxBubbleWidth: CGFloat {
        ChatLayout.maxBubbleWidth(in: DeviceMetrics.screenWidth)
    }

    /// A Captain reply carrying an action block, parsed for display. `nil`
    /// for every other message — and for anything Captain said without a
    /// well-formed fence, which renders as ordinary text.
    ///
    /// The same parse drives the engine's application of those actions, so
    /// the card below can never disagree with what actually happened.
    private var captainReply: CaptainReply? {
        guard !message.isFromMe else { return nil }
        return CaptainReply.parse(message.text)
    }

    /// True when this bubble is one of Captain's own replies. Captain is the
    /// Chief of Staff, not a worker: his thread is a management surface, so a
    /// reply renders as a short status line plus the manifest card rather than
    /// a full chat-style paragraph.
    private var isCaptainReply: Bool {
        !message.isFromMe && message.bot?.id == CaptainProfile.id
    }

    /// The body as the reader should see it.
    ///
    /// A Captain reply is collapsed to one status line: the two long
    /// paragraphs a Chief of Staff naturally writes belong in the transcript,
    /// not in a bubble the user has to scroll past to reach their crews.
    /// Everything else renders its full prose, with any action fence lifted
    /// out into the manifest card.
    private var displayText: String {
        if isCaptainReply { return captainStatusLine }
        return captainReply?.prose ?? message.text
    }

    /// One line naming what Captain actually did this turn, derived from the
    /// validated actions so it can never claim more than the store received.
    private var captainStatusLine: String {
        guard let reply = captainReply else {
            // Plain management chatter: keep the first sentence so the user
            // gets the instruction, without the essay behind it.
            return Self.firstSentence(of: message.text)
        }
        if let failure = reply.failure {
            return "Couldn’t apply that plan — \(failure)"
        }
        let crews = reply.actions.filter {
            if case .createCrew = $0 { return true }
            return false
        }.count
        let specialists = reply.actions.filter {
            if case .createSpecialist = $0 { return true }
            return false
        }.count
        if crews > 0, specialists > 0 {
            return "Assembled \(crews) crew\(crews == 1 ? "" : "s") and \(specialists) specialist\(specialists == 1 ? "" : "s")."
        }
        if crews > 0 {
            return crews == 1
                ? "Crew assembled. Open it from the dashboard to start work."
                : "\(crews) crews assembled. Open one from the dashboard to start work."
        }
        if specialists > 0 {
            return specialists == 1
                ? "Added a specialist to the roster."
                : "Added \(specialists) specialists to the roster."
        }
        return "Plan reviewed. No roster changes this turn."
    }

    /// The first sentence of a body, capped so a reply with no action block
    /// still reads as a status line rather than a paragraph.
    static func firstSentence(of text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return "" }
        if let stop = flattened.firstIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
            let sentence = String(flattened[...stop])
            if sentence.count <= 180 { return sentence }
        }
        return flattened.count <= 180 ? flattened : String(flattened.prefix(179)) + "…"
    }

    /// Analysed once per body change and memoised by content hash.
    private var analysis: MessageContent.Analysis {
        MessageContentCache.shared.analysis(for: displayText)
    }

    /// One attributed document for the whole body; memoised per message.
    private var document: NSAttributedString {
        MessageTextCache.shared.document(for: message.id,
                                         source: displayText,
                                         analysis: analysis,
                                         scheme: scheme)
    }

    private var resolvedTimeText: String { timeText ?? message.timeText }

    var body: some View {
        ChatBubbleLayout(maxWidth: maxBubbleWidth,
                         oppositeInset: ChatLayout.oppositeSideMinInset,
                         isOutgoing: isOutgoing) {
            bubble
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        .alert("Message info", isPresented: $showInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(infoText)
        }
    }

    // MARK: - Bubble

    private var bubble: some View {
        content
            .padding(.horizontal, ChatLayout.bubblePaddingH)
            .padding(.vertical, ChatLayout.bubblePaddingV)
            .background {
                bubbleShape
                    .fill(isOutgoing ? Theme.outgoingBubble(scheme)
                                     : Theme.incomingBubble(scheme))
                    .shadow(color: isOutgoing ? .clear : Theme.bubbleShadow(scheme),
                            radius: 0.5, y: 0.5)
            }
            .overlay {
                if !isOutgoing {
                    bubbleShape.stroke(Theme.bubbleBorder(scheme), lineWidth: 0.5)
                }
            }
    }

    private var bubbleShape: BubbleShape {
        BubbleShape(isOutgoing: isOutgoing, tail: showTail)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: ChatLayout.bubbleContentSpacing) {
            if message.hasQuote { quoteStrip }

            if let image = message.uiImage { photoView(image) }

            if displayText.isEmpty, captainReply == nil {
                metaTrailing
            } else {
                if !displayText.isEmpty {
                    if showsInlineMeta {
                        // Short prose carries the timestamp on its last line;
                        // the document is inset so the two do not overlap.
                        HStack(alignment: .bottom,
                               spacing: ChatLayout.inlineMetaSpacing) {
                            SelectableMessageText(document: document,
                                                  maxWidth: textMaxWidth)
                            meta
                        }
                    } else {
                        SelectableMessageText(document: document,
                                              maxWidth: textMaxWidth)
                    }
                }

                // Captain's structured action block, worn as a crew roster
                // card instead of raw JSON.
                if let captainReply, captainReply.hasCard {
                    CrewManifestCard(actions: captainReply.actions,
                                     failure: captainReply.failure)
                        .padding(.top, 2)
                }

                if !showsInlineMeta { metaTrailing }
            }
        }
    }

    /// Width the text document may occupy: the bubble's cap minus padding and,
    /// on the shared-line layout, the metadata's own width.
    private var textMaxWidth: CGFloat {
        let padding = 2 * ChatLayout.bubblePaddingH
        let reserved = showsInlineMeta
            ? ChatLayout.inlineMetaSpacing + inlineMetaWidth
            : 0
        return max(40, maxBubbleWidth - padding - reserved)
    }

    /// The metadata (time + ticks) never wraps; reserve its measured width.
    private var inlineMetaWidth: CGFloat {
        let time = (resolvedTimeText as NSString).size(
            withAttributes: [.font: UIFont.systemFont(ofSize: 10.5)]
        ).width
        let ticks: CGFloat = isOutgoing ? 26 : 0
        return ceil(time + ticks + 32)
    }

    /// True when the timestamp shares the body's last line.
    private var showsInlineMeta: Bool {
        // A manifest card always sits under the prose, so the meta line keeps
        // its own trailing slot instead of splitting the two.
        guard captainReply?.hasCard != true else { return false }
        guard !message.hasQuote, !message.hasImage else { return false }
        guard case .plain(let text) = analysis, !text.contains("\n") else {
            return false
        }
        return text.count <= ChatLayout.inlineMetaCharacterLimit
    }

    // MARK: - Actions

    /// The bubble's action menu. Long-press on the text belongs to selection,
    /// so the actions moved to an explicit affordance.
    private var actionsButton: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.bubbleMeta(scheme))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Message actions")
        .accessibilityIdentifier("message-actions")
        .accessibilityValue(message.text)
    }

    /// Copy here takes the raw source; the text view copies only its selection.
    @ViewBuilder
    private var menuItems: some View {
        if !message.text.isEmpty {
            Button {
                UIPasteboard.general.string = message.text
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }

        if let onReply {
            Button {
                onReply()
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
        }

        if canRegenerate, let onRegenerate {
            Button {
                onRegenerate()
            } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
        }

        Button {
            presentShare()
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }

        Button {
            showInfo = true
        } label: {
            Label("Info", systemImage: "info.circle")
        }

        if let onDelete {
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Shares the text, the image, or both, depending on what the message holds.
    private func presentShare() {
        var items: [Any] = []
        if let image = message.uiImage { items.append(image) }
        if !message.text.isEmpty { items.append(message.text) }
        guard !items.isEmpty else { return }
        shareItems = items
        showShareSheet = true
    }

    private func photoView(_ image: UIImage) -> some View {
        let size = displaySize(for: image)
        return Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(Text("Photo"))
    }

    /// Fits the photo inside the bubble's usable width, preserving its aspect
    /// ratio, with nothing cropped and nothing stretched.
    private func displaySize(for image: UIImage) -> CGSize {
        let maxWidth = maxBubbleWidth - 2 * ChatLayout.bubblePaddingH
        let maxHeight = ChatLayout.imageMaxHeight
        let source = image.size
        guard source.width > 0, source.height > 0 else {
            return CGSize(width: maxWidth, height: maxWidth)
        }
        let scale = min(maxWidth / source.width, maxHeight / source.height)
        return CGSize(width: (source.width * scale).rounded(),
                      height: (source.height * scale).rounded())
    }

    // MARK: - Quote strip

    /// The quoted message shown at the top of a reply.
    private var quoteStrip: some View {
        let accent = message.replyToIsMine ? Theme.accentDeep : Theme.linkBlue
        return HStack(spacing: 0) {
            Capsule()
                .fill(accent)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(message.replyToAuthor ?? "Message")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                Text(message.quotePreview.isEmpty ? "Photo" : message.quotePreview)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.leading, 7)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Color.black.opacity(scheme == .dark ? 0.18 : 0.05),
                    in: RoundedRectangle(cornerRadius: 5))
    }

    // MARK: - Meta line

    /// Time and ticks beside the body, sized to sit on the same baseline.
    private var meta: some View {
        metaContent
            .padding(.bottom, 1)
    }

    /// Time and ticks on their own trailing line.
    private var metaTrailing: some View {
        HStack(spacing: 3) {
            Spacer(minLength: 0)
            metaContent
        }
    }

    private var metaContent: some View {
        HStack(spacing: 3) {
            Text(resolvedTimeText)
                .font(.system(size: 10.5))
            if isOutgoing {
                DeliveryTicks(state: message.delivery)
            }
            actionsButton
        }
        .foregroundStyle(Theme.bubbleMeta(scheme))
    }

    // MARK: - Message detail

    /// Full detail for a single message: direction, exact timestamp, delivery
    /// state in plain language, and any attachment.
    private var infoText: String {
        var lines: [String] = [
            isOutgoing ? "Sent by you" : "Received",
            "Date: \(message.dateText)",
            "Time: \(message.fullTimestamp)",
            "Status: \(deliveryDescription)",
        ]
        if message.hasImage { lines.append("Attachment: photo") }
        if message.hasQuote, let author = message.replyToAuthor {
            lines.append("In reply to: \(author)")
        }
        return lines.joined(separator: "\n")
    }

    private var deliveryDescription: String {
        switch message.delivery {
        case .sending:   return "Sending"
        case .sent:      return "Sent"
        case .delivered: return "Delivered"
        case .read:      return "Read"
        case .failed:    return "Failed to send"
        }
    }
}
