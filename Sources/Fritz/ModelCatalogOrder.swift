import Foundation

extension DiscoveredAIModel {
    /// A display heuristic, not a benchmark: current chat families precede legacy and specialty models.
    public static func preferredOrder(_ models: [Self], provider: AIProviderKind) -> [Self] {
        models.map { (model: $0, preference: CatalogPreference(id: $0.id, provider: provider)) }
            .sorted { lhs, rhs in
                let a = lhs.preference, b = rhs.preference
                if a.group != b.group { return a.group < b.group }
                if a.family != b.family { return a.family < b.family }
                if a.version != b.version {
                    return b.version.lexicographicallyPrecedes(a.version)
                }
                if a.variant != b.variant { return a.variant < b.variant }
                let comparison = lhs.model.displayName.localizedStandardCompare(rhs.model.displayName)
                return comparison == .orderedSame ? lhs.model.id < rhs.model.id : comparison == .orderedAscending
            }
            .map(\.model)
    }
}

private struct CatalogPreference {
    let group: Int
    let family: String
    let version: [Int]
    let variant: Int

    init(id: String, provider: AIProviderKind) {
        let name = String(id.lowercased().split(separator: "/").last ?? "")
        let knownFamily = ["gpt", "claude", "gemini", "qwen", "llama", "deepseek", "mistral"]
            .first { name.hasPrefix($0) }
        let isOSeries = name.first == "o" && name.dropFirst().first?.isNumber == true
        family = knownFamily ?? (isOSeries ? "o" : "")
        // Support both 4.5 and 4-5 versions without treating dated snapshots as generations.
        version = family.isEmpty ? [] : name.firstMatch(of: /\d+(?:[.-]\d{1,2}(?!\d))?/)
            .map { $0.output.split(whereSeparator: { $0 == "." || $0 == "-" }).compactMap { Int($0) } } ?? []
        let tokens = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if tokens.contains("pro") || tokens.contains("opus") { variant = 0 }
        else if tokens.contains("nano") || tokens.contains("lite") { variant = 3 }
        else if tokens.contains("mini") || tokens.contains("flash") || tokens.contains("haiku") { variant = 2 }
        else { variant = 1 }

        if !ChatModelOption.Capabilities.inferred(provider: provider, modelID: name).isRecommendedInChatPicker {
            group = 5
        } else if ["ada", "babbage", "curie", "davinci", "text-davinci"].contains(where: { name.hasPrefix($0) })
                    || family == "gpt" && (version.first ?? 0) < 4 {
            group = 4
        } else if family == "gpt" && (version.first ?? 0) == 4 {
            group = 2
        } else if isOSeries || name == "chat-latest" || name.hasPrefix("chatgpt-") {
            group = 1
        } else {
            group = family.isEmpty ? 3 : 0
        }
    }
}
