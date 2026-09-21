import Foundation
import SwiftData

/// One structured, validated action Captain may request.
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

    /// Extracts the first fenced ```confabula-actions block from a reply.
    /// Tolerant of ```json-confabula-actions too, since models prepend the
    /// language tag unprompted.
    static func envelope(in reply: String) -> String? {
        guard let start = reply.range(of: "```confabula-actions") else { return nil }
        // Optional language tag may carry a suffix; find the end of line.
        let body = reply[start.upperBound...]
        guard let lineEnd = body.firstRange(of: "\n") else { return nil }
        let payload = body[lineEnd.upperBound...]
        guard let end = payload.range(of: "```") else { return nil }
        return String(payload[lineEnd.upperBound..<end.lowerBound])
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
    /// Result of applying a batch. `actions` are the summaries shown to the
    /// user in the chat as system-style confirmation rows.
    struct BatchResult: Equatable {
        var applied: [String]
        var createdBotIDs: [UUID]
        /// Crews assembled by this batch, in declaration order.
        var createdCrewIDs: [UUID]
    }

    enum ApplyError: LocalizedError {
        case duplicateName(String)
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .duplicateName(let name):
                return "A bot named “\(name)” already exists. Captain cannot overwrite it."
            case .saveFailed(let message):
                return message
            }
        }
    }

    /// Applies every action or none. A failed save rolls the whole batch back
    /// so a half-applied plan can never linger.
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
            return BatchResult(applied: [], createdBotIDs: [], createdCrewIDs: [])
        }

        var takenNames = Set(existingBots.map { $0.name.lowercased() })
        var created: [Bot] = []
        var createdCrews: [Crew] = []
        var applied: [String] = []

        for action in actions {
            switch action {
            case .createCrew(let crewSpec):
                var memberBots: [Bot] = []
                for spec in crewSpec.members {
                    let key = spec.name.lowercased()
                    guard !takenNames.contains(key) else {
                        created.forEach { context.delete($0) }
                        createdCrews.forEach { context.delete($0) }
                        throw ApplyError.duplicateName(spec.name)
                    }
                    let bot = makeSpecialistBot(from: spec)
                    context.insert(bot)
                    memberBots.append(bot)
                    created.append(bot)
                    takenNames.insert(key)
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
                guard !takenNames.contains(key) else {
                    created.forEach { context.delete($0) }
                    createdCrews.forEach { context.delete($0) }
                    throw ApplyError.duplicateName(spec.name)
                }
                let bot = makeSpecialistBot(from: spec)
                context.insert(bot)
                created.append(bot)
                takenNames.insert(key)
                applied.append(action.summary)
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
            createdCrewIDs: createdCrews.map(\.id))
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