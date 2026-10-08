import Foundation

/// One model call, after all of its provider usage fragments have been combined.
public struct ChatUsageCall: Codable, Equatable, Sendable {
    public let reported: Bool
    public let hasPricingTokens: Bool
    public let inputTokens: UInt64
    public let outputTokens: UInt64
    public let totalTokens: UInt64
    public let cachedInputTokens: UInt64
    public let cacheCreationInputTokens: UInt64
    public let providerCostUSD: Double?
    public let localDecision: Bool

    public init(reported: Bool, inputTokens: UInt64, outputTokens: UInt64, totalTokens: UInt64,
                cachedInputTokens: UInt64 = 0, cacheCreationInputTokens: UInt64 = 0,
                providerCostUSD: Double? = nil, localDecision: Bool = false, hasPricingTokens: Bool? = nil) {
        self.hasPricingTokens = hasPricingTokens ?? reported
        self.reported = reported; self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.totalTokens = totalTokens; self.cachedInputTokens = cachedInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens; self.providerCostUSD = providerCostUSD
        self.localDecision = localDecision
    }

    /// Provider APIs use different counters; Anthropic cache reads/writes are additional input,
    /// while Gemini's thought tokens are additional output. Other adapters include them.
    public init(provider: AIProviderKind, rawUsage: [String: Any]) {
        func count(_ names: [String], in values: [String: Any]? = nil) -> UInt64? {
            for name in names {
                if let number = (values ?? rawUsage)[name] as? NSNumber,
                   number.doubleValue.isFinite, number.doubleValue >= 0,
                   number.doubleValue.rounded(.towardZero) == number.doubleValue,
                   number.doubleValue <= Double(UInt64.max / 4) { return number.uint64Value }
            }
            return nil
        }
        let input = count(["input_tokens", "prompt_tokens", "promptTokenCount"])
        let output = count(["output_tokens", "completion_tokens", "candidatesTokenCount"])
        let read = count(["cached_input_tokens", "cache_read_input_tokens", "cachedContentTokenCount"])
            ?? count(["cached_tokens"], in: rawUsage["input_tokens_details"] as? [String: Any])
            ?? count(["cached_tokens"], in: rawUsage["prompt_tokens_details"] as? [String: Any]) ?? 0
        let write = count(["cache_creation_input_tokens"]) ?? 0
        let actualInput = (input ?? 0) + (provider == .anthropic ? read + write : 0)
        let actualOutput = (output ?? 0) + (provider == .gemini ? count(["thoughtsTokenCount"]) ?? 0 : 0)
        let cost = (rawUsage["provider_cost_usd"] ?? rawUsage["cost"]) as? Double
        let total = count(["total_tokens", "totalTokenCount"])
        self.init(reported: (total != nil || (input != nil && output != nil)) && rawUsage["reported"] as? Bool != false,
                  inputTokens: actualInput, outputTokens: actualOutput,
                  totalTokens: total ?? actualInput + actualOutput,
                  cachedInputTokens: read, cacheCreationInputTokens: write,
                  providerCostUSD: cost.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                  localDecision: rawUsage["local_decision"] as? Bool == true,
                  hasPricingTokens: input != nil && output != nil && rawUsage["reported"] as? Bool != false)
    }
}

public struct ChatUsage: Codable, Equatable, Sendable {
    public private(set) var calls: [ChatUsageCall]
    public init(calls: [ChatUsageCall] = []) { self.calls = calls }
    public mutating func append(_ call: ChatUsageCall) { calls.append(call) }
    public var modelCalls: Int { calls.count }
    public var reportedModelCalls: Int { calls.filter(\.reported).count }
    public var unreportedModelCalls: Int { modelCalls - reportedModelCalls }
    public var knownTokens: UInt64 { calls.reduce(0) { $0 + $1.totalTokens } }
    public var cachedInputTokens: UInt64 { calls.reduce(0) { $0 + $1.cachedInputTokens } }
}

public struct ChatUsageCostBreakdown: Sendable {
    public let uncachedInputUSD: Double
    public let cachedInputUSD: Double
    public let outputUSD: Double
    public var totalUSD: Double { uncachedInputUSD + cachedInputUSD + outputUSD }
}
