import Foundation

/// One finished Captain reply, split for display: the human prose with the
/// fenced action block lifted out, and the block decoded into the crew
/// entries the chat renders as a manifest card.
///
/// A reply without a block parses to `nil`, so ordinary bubbles take the
/// ordinary path. A block whose JSON fails validation still leaves the raw
/// fence out of the bubble — Captain's error already surfaced in the chat,
/// and showing half a machine payload serves nobody.
struct CaptainReply: Equatable {
    /// The reply with the entire fenced block removed, trimmed.
    var prose: String
    /// Validated actions from the block (empty when the block failed).
    var actions: [CaptainAction]
    /// Why the block could not be applied, when it could not.
    var failure: String?

    /// Whether a manifest card should accompany the prose.
    var hasCard: Bool { !actions.isEmpty || failure != nil }

    /// The fence that opens an action block.
    private static let fence = "```confabula-actions"

    static func parse(_ text: String) -> CaptainReply? {
        guard let opening = text.range(of: fence) else { return nil }
        let afterMarker = text[opening.upperBound...]
        guard let firstLine = afterMarker.firstRange(of: "\n"),
              let closing = afterMarker[firstLine.upperBound...].range(of: "```")
        else { return nil }

        let blockRange = opening.lowerBound..<closing.upperBound
        let payload = String(afterMarker[firstLine.upperBound..<closing.lowerBound])

        var prose = text
        prose.removeSubrange(blockRange)
        // The removed block usually sat on its own line between paragraphs;
        // without this the bubble shows a three-blank-line canyon where the
        // fence used to be.
        while let gap = prose.range(of: "\n\n\n") {
            prose.replaceSubrange(gap, with: "\n\n")
        }
        prose = prose.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = payload.data(using: .utf8) else {
            return CaptainReply(prose: prose, actions: [],
                                failure: "The action block was not readable.")
        }
        switch CaptainAction.decode(from: data) {
        case .success(let actions):
            return CaptainReply(prose: prose, actions: actions, failure: nil)
        case .failure(let error):
            return CaptainReply(prose: prose, actions: [],
                                failure: error.localizedDescription)
        }
    }
}
