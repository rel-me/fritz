import Fritz
import SwiftUI

public struct ChatResponseUsageFooter: View {
    private let summary: ChatResponseUsageSummary

    public init(summary: ChatResponseUsageSummary) { self.summary = summary }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            labels
            VStack(alignment: .leading, spacing: 4) {
                Text(tokens)
                Text(cached)
                Text(summary.costLabel)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .help("\(summary.modelName). Cached input is included in total tokens. \(summary.costSource == "rel.me" ? "Prices from REL’s model catalog. " : "")Provider billing is authoritative.")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-response-usage-footer")
    }

    private var tokens: String {
        summary.usage.reportedModelCalls == 0 && summary.usage.knownTokens == 0 ? "Tokens unavailable" : "\(summary.usage.knownTokens.formatted()) tokens\(summary.usage.unreportedModelCalls > 0 ? " (partial)" : "")"
    }
    private var cached: String {
        summary.usage.reportedModelCalls == 0 ? "Cached tokens unavailable" : "\(summary.usage.cachedInputTokens.formatted()) cached"
    }
    private var labels: some View {
        HStack(spacing: 8) {
            Text(tokens)
            Text("·")
            Text(cached)
            Text("·")
            Text(summary.costLabel)
        }
    }
}
