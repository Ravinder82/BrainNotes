import Foundation

/// Immutable request attribution without message text.
struct AIRequestRecord: Identifiable, Equatable {
    let id: UUID
    let botID: UUID
    let botName: String
    let providerLabel: String
    let providerBaseURL: String
    let model: String
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let recordedAt: Date
    let outcome: Outcome

    enum Outcome: String, Codable {
        case completed, failed, cancelled
    }

    init(
        id: UUID = UUID(), botID: UUID, botName: String,
        providerLabel: String, providerBaseURL: String, model: String,
        promptTokens: Int? = nil, completionTokens: Int? = nil,
        totalTokens: Int? = nil, recordedAt: Date = Date(),
        outcome: Outcome = .completed
    ) {
        self.id = id
        self.botID = botID
        self.botName = botName
        self.providerLabel = providerLabel
        self.providerBaseURL = providerBaseURL
        self.model = model
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.recordedAt = recordedAt
        self.outcome = outcome
    }
}

struct UsageSummary {
    let requestCount: Int
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?

    static func of(_ records: [AIRequestRecord]) -> UsageSummary {
        let completed = records.filter { $0.outcome == .completed }
        func sum(_ keyPath: KeyPath<AIRequestRecord, Int?>) -> Int? {
            let values = completed.compactMap { $0[keyPath: keyPath] }
            return values.isEmpty ? nil : values.reduce(0, +)
        }
        return UsageSummary(
            requestCount: records.count,
            promptTokens: sum(\.promptTokens),
            completionTokens: sum(\.completionTokens),
            totalTokens: sum(\.totalTokens))
    }
}
