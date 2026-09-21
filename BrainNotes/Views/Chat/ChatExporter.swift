import Foundation

/// Turns a selection of messages into text another app can consume.
///
/// A free function over plain values rather than a method on the view: the
/// format is worth testing, and keeping it here means the chat screen has no
/// string-assembly logic in it.
enum ChatExporter {

    /// Readable transcript of `messages`, in the order given.
    ///
    /// Deliberately strips markup down to prose — raw `**` and `[]()` in a
    /// shared file would be noise — while keeping the author and full timestamp
    /// on every line, because a transcript is read out of context.
    static func plainText(messages: [Message], botName: String) -> String {
        var lines: [String] = ["Chat with \(botName)"]
        lines.append(String(repeating: "-", count: 24))

        for message in messages {
            let author = message.isFromMe ? "You" : botName
            var line = "[\(message.fullTimestamp)] \(author):"
            let body = MessagePreviewCache.shared.plain(from: message.text)
            if !body.isEmpty { line += " \(body)" }
            if message.hasImage { line += " [photo]" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}