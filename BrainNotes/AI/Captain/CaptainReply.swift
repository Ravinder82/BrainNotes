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

    /// The block is located by the same `FencedBlock` the engine executes
    /// from, so display and execution can never disagree — and a model's
    /// unprompted ```json-confabula-actions tag parses here exactly as it
    /// does there.
    static func parse(_ text: String) -> CaptainReply? {
        guard let block = FencedBlock.first(in: text, marker: "confabula-actions")
        else { return nil }

        var prose = text
        prose.removeSubrange(block.full)
        // The removed block usually sat on its own line between paragraphs;
        // without this the bubble shows a three-blank-line canyon where the
        // fence used to be.
        while let gap = prose.range(of: "\n\n\n") {
            prose.replaceSubrange(gap, with: "\n\n")
        }
        prose = prose.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = block.payload.data(using: .utf8) else {
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

    /// What the bubble shows for a finished Captain reply.
    ///
    /// When a card carries the detail — applied actions, or a validation
    /// failure — the prose collapses to one status line: Captain's thread is
    /// a management surface, and the card says what happened. With no card
    /// the reply *is* the content: the first-run interview question, an
    /// answer, a critique. It must show in full. (It used to be cut to its
    /// first sentence, which hid everything after an opening
    /// "Understood." and read as Captain producing no output.)
    static func statusLine(forReply text: String) -> String {
        guard let reply = parse(text) else {
            // Plain prose — shown in full. A block the stream cut off
            // mid-fence is stripped rather than shown as machine syntax.
            return CaptainAction.stripBlocks(text)
        }
        if let failure = reply.failure {
            return "Couldn\u{2019}t apply that plan — \(failure)"
        }
        guard !reply.actions.isEmpty else {
            // A fence that carried nothing to act on: the prose is the
            // content, and a canned line would hide it the same way the
            // old first-sentence cut did.
            return reply.prose.isEmpty
                ? "Plan reviewed. No roster changes this turn."
                : reply.prose
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
}
