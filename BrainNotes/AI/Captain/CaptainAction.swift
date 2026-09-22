import Foundation
import SwiftData

/// Locates one ```-fenced block in a reply by its tag marker.
///
/// Shared by the action parser (display and engine alike) and the web-tool
/// parser, so the three can never disagree about where a block starts or
/// ends — they used to be three hand-copied variants of the same five lines,
/// and the copies had already drifted. Tolerant of a language tag before the
/// marker (```json-confabula-actions), because models prepend one unprompted
/// even when the prompt shows the bare fence.
enum FencedBlock {
    struct Found {
        /// The text between the fences, without either fence line.
        let payload: String
        /// Both fence lines and everything between them — a range to cut
        /// from prose when the block must not reach the reader.
        let full: Range<String.Index>
    }

    /// The first complete fenced block carrying `marker`, or `nil` — both
    /// when the marker is absent and when its block never closed, because a
    /// partial payload cannot be decoded and must not swallow the reply.
    static func first(in text: String, marker: String) -> Found? {
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let tag = text.range(of: marker, range: searchStart..<text.endIndex) {
            // The tag must sit on a line that opens with a fence; a prose
            // mention of the marker is skipped in favour of a later real one.
            let lineStart = lineStart(of: tag.lowerBound, in: text)
            guard text[lineStart...].hasPrefix("```") else {
                searchStart = tag.upperBound
                continue
            }
            let afterTag = text[tag.upperBound...]
            guard let lineEnd = afterTag.firstRange(of: "\n"),
                  let close = text.range(of: "```",
                                         range: lineEnd.upperBound..<text.endIndex)
            else { return nil }
            return Found(payload: String(text[lineEnd.upperBound..<close.lowerBound]),
                         full: lineStart..<close.upperBound)
        }
        return nil
    }

    /// Every complete block removed, plus an unclosed opener dropped from its
    /// line to the end — so no failure path or bubble can leak machine syntax.
    static func stripAll(in text: String, marker: String) -> String {
        var result = text
        while let block = first(in: result, marker: marker) {
            result.removeSubrange(block.full)
        }
        var searchStart = result.startIndex
        while searchStart < result.endIndex,
              let tag = result.range(of: marker, range: searchStart..<result.endIndex) {
            let lineStart = lineStart(of: tag.lowerBound, in: result)
            guard result[lineStart...].hasPrefix("```") else {
                searchStart = tag.upperBound
                continue
            }
            result.removeSubrange(lineStart..<result.endIndex)
            break
        }
        // The removed block usually sat on its own line between paragraphs;
        // without collapsing, the bubble shows a blank canyon where it was.
        while let gap = result.range(of: "\n\n\n") {
            result.replaceSubrange(gap, with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lineStart(of index: String.Index, in text: String) -> String.Index {
        var i = index
        while i > text.startIndex, text[text.index(before: i)] != "\n" {
            i = text.index(before: i)
        }
        return i
    }
}

/// One structured, validated Captain action may request.
///
/// Captain's *text* is never authority. The only way Captain changes anything
/// is by emitting a fenced ```confabula-actions block containing JSON that
/// passes validation here. Everything else it says is prose.
enum CaptainAction: Equatable {
    /// Create a crew — Captain's primary unit of work. A crew bundles 2–6
    /// specialists with one shared mission so Captain can stay free as Chief
    /// of Staff. `create_specialist` still exists for the rare lone operator
    /// case; the system prompt now steers Captain to `create_crew` first.
    case createCrew(CreateCrew)

    /// Lone-specialist fallback. Captain emits this only when a request really
    /// needs a single owner with no team context.
    case createSpecialist(CreateSpecialist)

    struct CreateSpecialist: Equatable {
        var name: String
        var role: String
        var responsibilities: [String]
        var negativeRules: String
        var agePerspective: Int
        var creativity: Double
    }

    struct CreateCrew: Equatable {
        /// Crew display name, e.g. "Content Squad".
        var name: String
        /// One-line mission, e.g. "Drafts the weekly short-form scripts."
        var mission: String
        /// Emoji for the avatar, e.g. "🎬".
        var emoji: String
        /// Accent hex for the card border and avatar disc.
        var accentColorHex: String
        /// The specialists who make up this crew, in the order they should
        /// appear on the card's avatar stack.
        var members: [CreateSpecialist]
    }

    /// Human-readable summary for the activity surface.
    var summary: String {
        switch self {
        case .createCrew(let crew):
            let count = crew.members.count
            return "Assemble crew “\(crew.name)” with \(count) specialist\(count == 1 ? "" : "s")"
        case .createSpecialist(let spec):
            return "Create specialist “\(spec.name)” — \(spec.role)"
        }
    }

    // MARK: - Envelope

    /// Extracts the payload of the first fenced ```confabula-actions block
    /// from a reply. Shares `FencedBlock` with the display parser, so the
    /// engine and the bubble can never disagree — and, like it, accepts a
    /// model's unprompted ```json-confabula-actions language tag.
    static func envelope(in reply: String) -> String? {
        FencedBlock.first(in: reply, marker: "confabula-actions")?.payload
    }

    /// Removes every action block — complete or cut off mid-fence — from a
    /// reply, so a failure path or a bubble can never show machine syntax.
    static func stripBlocks(_ text: String) -> String {
        FencedBlock.stripAll(in: text, marker: "confabula-actions")
    }

    // MARK: - Validation

    enum ValidationError: LocalizedError, Equatable {
        case malformedJSON(String)
        case unknownAction(String)
        case missing(String)
        case nameTooLong
        case crewNameTooLong
        case missionTooLong
        case tooManyResponsibilities
        case invalidAge(Int)
        case invalidCreativity(Double)
        case crewEmpty
        case crewTooLarge(Int)
        case duplicateSpecialistName(String)
        case emojiTooLong

        var errorDescription: String? {
            switch self {
            case .malformedJSON: return "The action block was not valid JSON."
            case .unknownAction(let kind): return "Unknown action “\(kind)”."
            case .missing(let field): return "Missing “\(field)”."
            case .nameTooLong: return "Specialist name is too long (max 60 characters)."
            case .crewNameTooLong: return "Crew name is too long (max 40 characters)."
            case .missionTooLong: return "Crew mission is too long (max 140 characters)."
            case .tooManyResponsibilities: return "At most 8 responsibilities are allowed."
            case .invalidAge(let age): return "Age \(age) is outside the 12–50 range."
            case .invalidCreativity(let c): return "Creativity \(c) is outside 0.0–1.0."
            case .crewEmpty: return "A crew needs at least 2 specialists."
            case .crewTooLarge(let n): return "A crew can hold at most 6 specialists (got \(n))."
            case .duplicateSpecialistName(let n): return "Duplicate specialist name “\(n)” inside the crew."
            case .emojiTooLong: return "Crew emoji should be a single grapheme."
            }
        }
    }

    /// Validates and decodes one action from a raw JSON object.
    static func decode(from data: Data) -> Result<[CaptainAction], ValidationError> {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return .failure(.malformedJSON(error.localizedDescription))
        }
        guard let array = root as? [Any] else {
            return .failure(.malformedJSON("Expected a JSON array of actions."))
        }
        var actions: [CaptainAction] = []
        for element in array {
            guard let obj = element as? [String: Any] else {
                return .failure(.malformedJSON("Each action must be an object."))
            }
            guard let kind = obj["action"] as? String else {
                return .failure(.missing("action"))
            }
            switch kind {
            case "create_crew":
                let crew: CreateCrew
                do {
                    crew = try decodeCrew(obj)
                } catch let error as ValidationError {
                    return .failure(error)
                } catch {
                    return .failure(.malformedJSON(String(describing: error)))
                }
                actions.append(.createCrew(crew))
            case "create_specialist":
                let spec: CreateSpecialist
                do {
                    spec = try decodeSpecialist(obj)
                } catch let error as ValidationError {
                    return .failure(error)
                } catch {
                    return .failure(.malformedJSON(String(describing: error)))
                }
                actions.append(.createSpecialist(spec))
            default:
                return .failure(.unknownAction(kind))
            }
        }
        return .success(actions)
    }

    private static func decodeSpecialist(_ obj: [String: Any]) throws -> CreateSpecialist {
        guard let name = obj["name"] as? String else { throw ValidationError.missing("name") }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ValidationError.missing("name") }
        guard trimmedName.count <= 60 else { throw ValidationError.nameTooLong }
        guard let role = (obj["role"] as? String)?.nilIfBlank else { throw ValidationError.missing("role") }

        var responsibilities: [String] = []
        if let raw = obj["responsibilities"] as? [Any] {
            let items = raw.compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard items.count <= 8 else { throw ValidationError.tooManyResponsibilities }
            responsibilities = items
        }

        let age = obj["agePerspective"] as? Int ?? Bot.defaultAgePerspective
        guard (12...50).contains(age) else { throw ValidationError.invalidAge(age) }

        let creativityRaw = obj["creativity"] as? Double
            ?? (obj["creativity"] as? Int).map(Double.init)
            ?? 0.5
        guard creativityRaw.isFinite, (0.0...1.0).contains(creativityRaw) else {
            throw ValidationError.invalidCreativity(creativityRaw)
        }

        let negativeRules = (obj["negativeRules"] as? String) ?? ""

        return CreateSpecialist(
            name: trimmedName,
            role: role,
            responsibilities: responsibilities,
            negativeRules: negativeRules,
            agePerspective: age,
            creativity: creativityRaw)
    }

    private static func decodeCrew(_ obj: [String: Any]) throws -> CreateCrew {
        guard let name = obj["name"] as? String else { throw ValidationError.missing("name") }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ValidationError.missing("name") }
        guard trimmedName.count <= 40 else { throw ValidationError.crewNameTooLong }
        let mission = (obj["mission"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !mission.isEmpty else { throw ValidationError.missing("mission") }
        guard mission.count <= 140 else { throw ValidationError.missionTooLong }

        let emoji = ((obj["emoji"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "🎯"
        guard emoji.count <= 4 else { throw ValidationError.emojiTooLong }

        let accent = ((obj["accentColorHex"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Theme.accentHex

        guard let membersRaw = obj["members"] as? [Any] else {
            throw ValidationError.missing("members")
        }
        guard membersRaw.count >= 2 else { throw ValidationError.crewEmpty }
        guard membersRaw.count <= 6 else { throw ValidationError.crewTooLarge(membersRaw.count) }

        var seen = Set<String>()
        var specialists: [CreateSpecialist] = []
        for element in membersRaw {
            guard let memberObj = element as? [String: Any] else {
                throw ValidationError.malformedJSON("Each crew member must be an object.")
            }
            let spec = try decodeSpecialist(memberObj)
            let key = spec.name.lowercased()
            guard seen.insert(key).inserted else {
                throw ValidationError.duplicateSpecialistName(spec.name)
            }
            specialists.append(spec)
        }
        return CreateCrew(
            name: trimmedName,
            mission: mission,
            emoji: emoji,
            accentColorHex: accent,
            members: specialists)
    }
}

private extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// Applies validated Captain actions to the store. This — not Captain's prose
/// — is the only execution path.
struct CaptainActionProcessor {
    /// Result of applying a batch. `applied` are the summaries shown to the
    /// user in the chat as system-style confirmation rows.
    ///
    /// `replaced` covers the "new version of the same bot" case: a same-name
    /// `create_specialist` (or `create_crew` member) retires the old bot and
    /// its history. The manifest card and the applied-summary line distinguish
    /// a fresh creation from a replacement so the user can see what changed.
    /// One retired-and-replaced specialist. A named struct rather than a
    /// tuple so `BatchResult` keeps its synthesised `Equatable` conformance
    /// (tuples cannot participate in it).
    struct Replacement: Equatable {
        /// The freshly inserted bot that now carries the name.
        var newBotID: UUID
        /// The name as it was spelled on the retired bot, for the summary.
        var previousName: String
        /// The retired bot's version, so the manifest can show "v1 → v2".
        var previousVersion: Int
    }

    struct BatchResult: Equatable {
        var applied: [String]
        var createdBotIDs: [UUID]
        /// Crews assembled by this batch, in declaration order.
        var createdCrewIDs: [UUID]
        /// Bots whose older version was wiped and replaced by this batch, so
        /// the user can see that a specialist was revised rather than added.
        var replaced: [Replacement]
    }

    enum ApplyError: LocalizedError {
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let message):
                return message
            }
        }
    }

    /// Applies every action or none. A failed save rolls the whole batch back
    /// so a half-applied plan can never linger.
    ///
    /// Versioning rule: when a `create_specialist` (or a member inside a
    /// `create_crew`) targets a bot name that already exists, the old bot is
    /// retired — its messages and crew memberships are wiped, and the new bot
    /// takes over with `configurationVersion = oldVersion + 1`. Older versions
    /// are never kept alongside; the dashboard and crew cards always show the
    /// current version of every specialist.
    ///
    /// Main-actor isolated because it mutates a SwiftData context and reads
    /// `CaptainProfile.id` (a `@MainActor` static) to stamp the crew.
    @discardableResult
    @MainActor
    static func apply(
        _ actions: [CaptainAction],
        in context: ModelContext,
        existingBots: [Bot]
    ) throws -> BatchResult {
        guard !actions.isEmpty else {
            return BatchResult(applied: [], createdBotIDs: [],
                               createdCrewIDs: [], replaced: [])
        }

        // `byName` is the authoritative source of truth mid-batch. Captain may
        // emit two actions that target the same specialist in one block — the
        // first one retires an existing bot, and the second must see the
        // fresh one rather than the old one it just wiped.
        var byName: [String: Bot] = Dictionary(
            uniqueKeysWithValues: existingBots.map { ($0.name.lowercased(), $0) }
        )
        var created: [Bot] = []
        var createdCrews: [Crew] = []
        var applied: [String] = []
        var replaced: [Replacement] = []

        func retire(named: String) -> RetireInfo? {
            guard let old = byName[named.lowercased()] else { return nil }
            // SwiftData's `.cascade` on `Message.bot` tears down the retired
            // bot's own chat, and the `.nullify` inverse on `Crew.members`
            // drops it from every roster it belonged to. We delete the
            // messages explicitly as well so the 1:1 history is gone in the
            // same transaction the new version arrives in.
            for m in old.messages { context.delete(m) }
            byName.removeValue(forKey: named.lowercased())
            let info = RetireInfo(previousName: old.name,
                                  previousVersion: old.configurationVersion)
            context.delete(old)
            return info
        }

        for action in actions {
            switch action {
            case .createCrew(let crewSpec):
                var memberBots: [Bot] = []
                for spec in crewSpec.members {
                    let key = spec.name.lowercased()
                    let prior = retire(named: spec.name)
                    let bot = makeSpecialistBot(from: spec)
                    if let prior {
                        bot.configurationVersion = prior.previousVersion + 1
                        replaced.append(Replacement(newBotID: bot.id,
                                         previousName: prior.previousName,
                                         previousVersion: prior.previousVersion))
                        applied.append(
                            "Replace specialist “\(spec.name)” (v\(prior.previousVersion)) with the new version"
                        )
                    } else {
                        applied.append(action.summary)
                    }
                    context.insert(bot)
                    memberBots.append(bot)
                    created.append(bot)
                    byName[key] = bot
                }
                let crew = Crew(
                    name: crewSpec.name,
                    mission: crewSpec.mission,
                    emoji: crewSpec.emoji,
                    accentColorHex: crewSpec.accentColorHex,
                    members: memberBots,
                    assembledByID: CaptainProfile.id)
                context.insert(crew)
                createdCrews.append(crew)
                applied.append(action.summary)
            case .createSpecialist(let spec):
                let key = spec.name.lowercased()
                let prior = retire(named: spec.name)
                let bot = makeSpecialistBot(from: spec)
                if let prior {
                    bot.configurationVersion = prior.previousVersion + 1
                    replaced.append(Replacement(newBotID: bot.id,
                                     previousName: prior.previousName,
                                     previousVersion: prior.previousVersion))
                    applied.append(
                        "Replace specialist “\(spec.name)” (v\(prior.previousVersion)) with the new version"
                    )
                } else {
                    applied.append(action.summary)
                }
                context.insert(bot)
                created.append(bot)
                byName[key] = bot
            }
        }

        do {
            try context.save()
        } catch {
            created.forEach { context.delete($0) }
            createdCrews.forEach { context.delete($0) }
            throw ApplyError.saveFailed(error.localizedDescription)
        }
        return BatchResult(
            applied: applied,
            createdBotIDs: created.map(\.id),
            createdCrewIDs: createdCrews.map(\.id),
            replaced: replaced)
    }

    /// Internal carrier used to pass the retirement metadata back out of
    /// `retire(named:)`. Only the prior name and version are needed; the
    /// identity of the wiped bot is not, because `context.delete(old)` has
    /// already torn it down.
    fileprivate struct RetireInfo {
        let previousName: String
        let previousVersion: Int
    }


    /// One factory for both `create_crew` and `create_specialist` so the bot
    /// configuration stays in exactly one place.
    private static func makeSpecialistBot(from spec: CaptainAction.CreateSpecialist) -> Bot {
        let bot = Bot(
            name: spec.name,
            role: spec.role,
            negativeRules: spec.negativeRules,
            systemPersonality: spec.responsibilities.isEmpty
                ? "Created by Captain. Responsibilities were not specified yet — ask the user to refine them."
                : spec.responsibilities.map { "• \($0)" }.joined(separator: "\n"),
            agePerspective: spec.agePerspective,
            creativity: spec.creativity)
        bot.isCaptainManaged = true
        return bot
    }
}