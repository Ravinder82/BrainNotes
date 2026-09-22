import SwiftUI

/// The pinned composer at the bottom of a thread: attachment menu, quoted-reply
/// strip, staged-attachment strip, text field and the send/stop button.
///
/// The draft text lives in the chat screen, not here, because the screen also
/// fills it in from a document scan; everything else about the composer is
/// local to this view.
struct ChatComposerView: View {
    @Binding var draft: String
    let focus: FocusState<Bool>.Binding
    let bot: Bot

    /// The message being quoted by the current reply, if any.
    let replyTarget: Message?
    /// A photo staged for the next send, if any.
    let attachment: MessageAttachment?

    /// This bot's own reply is streaming, so the button stops instead of sends.
    let isStreamingHere: Bool
    /// Another bot's reply is streaming, so this composer must not send or stop.
    let isStreamingElsewhere: Bool
    /// Whether the model this bot uses accepts images.
    let canAttach: Bool

    var onSend: () -> Void
    var onStop: () -> Void
    var onCancelReply: () -> Void
    var onRemoveAttachment: () -> Void
    var onPickPhoto: () -> Void
    var onScanDocument: () -> Void
    var onRemoveBackground: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || attachment != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            if let replyTarget {
                ReplyPreviewRow(bot: bot,
                                target: replyTarget,
                                onCancel: onCancelReply)
            }

            if let attachment {
                AttachmentPreviewRow(attachment: attachment,
                                     onRemove: onRemoveAttachment)
            }

            HStack(alignment: .bottom, spacing: 8) {
                attachMenu
                textField
                sendButton
            }
            .padding(.horizontal, ChatLayout.composerPaddingH)
            .padding(.vertical, ChatLayout.composerPaddingV)
            .background(Theme.bar(scheme))
        }
    }

    // MARK: - Pieces

    private var attachMenu: some View {
        Menu {
            Button { onPickPhoto() } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }
            Button { onScanDocument() } label: {
                Label("Scan Document", systemImage: "doc.text.viewfinder")
            }
            Button { onRemoveBackground() } label: {
                Label("Remove Background", systemImage: "crop")
            }
        } label: {
     ZStack {
         if canAttach {
             Circle().fill(Theme.quietDisc(scheme))
             Circle().strokeBorder(Theme.hairline(scheme), lineWidth: 1)
         }
         Image(systemName: "plus")
             .font(.system(size: 16, weight: .semibold))
             .foregroundStyle(canAttach ? Theme.accentText(scheme)
                              : Color.secondary.opacity(0.5))
     }
     .frame(width: 44, height: 44)
     .contentShape(Circle())
 }
        .disabled(!canAttach || isStreamingHere)
        .opacity(isStreamingHere ? 0.4 : 1)
        .accessibilityIdentifier("attach-button")
        .accessibilityLabel(Text(canAttach
                                 ? "Add attachment"
                                 : "This model does not accept images"))
    }

    private var textField: some View {
        TextField("Message", text: $draft, axis: .vertical)
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
            .accessibilityIdentifier("message-field")
            .accessibilityLabel(Text("Message"))
    }

    private var sendButton: some View {
        Button {
            // Only this thread's own stream can be stopped from here; a reply
            // streaming in another bot must not be cancelled by this button.
            if isStreamingHere {
                onStop()
            } else {
                onSend()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(isEnabledSend ? Theme.accentDeep : Theme.quietDisc(scheme))
                Circle()
                    .strokeBorder(isEnabledSend ? Color.clear : Theme.hairline(scheme),
                                  lineWidth: 1)
                Image(systemName: isStreamingHere ? "stop.fill" : "arrow.up")
                    .font(.system(size: isStreamingHere ? 12 : 16, weight: .bold))
                    .foregroundStyle(isEnabledSend ? Color.white
                                     : Color.secondary.opacity(0.55))
            }
            .frame(width: 38, height: 38)
            .contentShape(Circle())
        }
        .disabled(isStreamingHere ? false : (!canSend || isStreamingElsewhere))
        .accessibilityLabel(Text(isStreamingHere ? "Stop" : "Send"))
        .accessibilityIdentifier("send-button")
    }

    /// The button's live colour state: streaming always offers Stop; otherwise
    /// send needs text (or an attachment) and no other thread streaming.
    private var isEnabledSend: Bool {
        isStreamingHere || (canSend && !isStreamingElsewhere)
    }
}

/// The quoted message shown above the composer while replying.
private struct ReplyPreviewRow: View {
    let bot: Bot
    let target: Message
    var onCancel: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var accent: Color {
        target.isFromMe ? Theme.accentText(scheme) : Theme.linkText(scheme)
    }

    var body: some View {
        HStack(spacing: 0) {
            Capsule()
                .fill(accent)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(target.isFromMe ? "You" : bot.name)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(accent)
                Text(target.hasImage && target.text.isEmpty
                     ? "Photo" : target.quotePreview)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.leading, 8)

            Spacer(minLength: 8)

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Cancel reply"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.raised(scheme),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.hairline(scheme), lineWidth: 1)
        )
        .padding(.horizontal, ChatLayout.composerPaddingH)
        .padding(.bottom, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// The staged photo shown above the composer, with its size, before sending.
private struct AttachmentPreviewRow: View {
    let attachment: MessageAttachment
    var onRemove: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            if let image = UIImage(data: attachment.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: ChatLayout.attachmentThumbnailSize,
                           height: ChatLayout.attachmentThumbnailSize)
                    .clipShape(RoundedRectangle(cornerRadius: ChatLayout.attachmentThumbnailRadius))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count),
                                               countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Remove attachment"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.raised(scheme),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.hairline(scheme), lineWidth: 1)
        )
        .padding(.horizontal, ChatLayout.composerPaddingH)
        .padding(.bottom, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}