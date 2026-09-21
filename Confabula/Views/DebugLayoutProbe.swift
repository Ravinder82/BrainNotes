import SwiftUI

/// TEMPORARY probe: bubble width hugging and tail rendering.
struct DebugLayoutProbe: View {
    private let short = Message(text: "Short one", author: .bot, delivery: .delivered)
    private let long = Message(
        text: "Incoming reply with enough words to wrap onto a second line in the bubble.",
        author: .bot, delivery: .delivered
    )

    private var thread: (Bot, ChatEngine) {
        let bot = Bot(name: "Probe")
        for (offset, text) in [
            "Hi! Send me anything.",
            "A second, much longer incoming message that has to wrap across two lines.",
            "Third one.",
        ].enumerated() {
            let message = Message(text: text, author: .bot,
                                  timestamp: Date().addingTimeInterval(Double(offset)),
                                  delivery: .delivered)
            message.bot = bot
        }
        return (bot, ChatEngine(providers: ProviderStore()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            label("A bubble then Spacer")
            HStack(alignment: .bottom, spacing: 0) {
                MessageBubble(message: short, showTail: true)
                Spacer(minLength: ChatLayout.oppositeSideMinInset)
            }

            label("B bubble layoutPriority(1) then Spacer")
            HStack(alignment: .bottom, spacing: 0) {
                MessageBubble(message: short, showTail: true).layoutPriority(1)
                Spacer(minLength: ChatLayout.oppositeSideMinInset)
            }

            label("C long message, bubble then Spacer")
            HStack(alignment: .bottom, spacing: 0) {
                MessageBubble(message: long, showTail: true)
                Spacer(minLength: ChatLayout.oppositeSideMinInset)
            }

            label("D real ChatThreadView")
            ChatThreadView(
                bot: thread.0,
                engine: thread.1,
                isSelecting: false,
                selectedIDs: [],
                openRow: .constant(nil),
                onDelete: { _ in }, onReply: { _ in }, onRegenerate: {},
                onToggleSelect: { _ in }, onTapRow: {}
            )
            .frame(height: 320)

            Spacer()
        }
        .padding(.horizontal, ChatLayout.threadPaddingH)
        .padding(.top, 40)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
