import Foundation

/// A completion-time snapshot, retained with the response rather than the current model selection.
public struct ChatResponseUsageSummary: Codable, Equatable, Sendable {
    public let usage: ChatUsage
    public let modelName: String
    public let costUSD: Double?
    public let costSource: String?

    public init(usage: ChatUsage, modelName: String, costUSD: Double?, costSource: String?) {
        self.usage = usage; self.modelName = modelName; self.costUSD = costUSD; self.costSource = costSource
    }

    public var costLabel: String {
        guard let costUSD else { return "Cost unavailable" }
        let amount = costUSD.formatted(.currency(code: "USD").precision(.fractionLength(costUSD > 0 && costUSD < 0.0001 ? 6 : costUSD > 0 && costUSD < 0.01 ? 4 : 2)))
        return "\(costSource == "provider" ? "Reported" : "Estimated") \(amount)"
    }
}
