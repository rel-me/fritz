public struct ChatModelPickerSection: Equatable, Identifiable, Sendable {
    public enum ID: Equatable, Hashable, Sendable {
        case recent
        case provider(AIProviderKind)
        case bedrock
    }

    public let id: ID
    public let title: String
    public let models: [ChatModelOption]

    public static func unfiltered(
        from models: [ChatModelOption],
        recentModels: [ChatModelOption],
        providerOrder: [AIProviderKind],
        selectedModelID: String? = nil,
        recentLimit: Int = 5,
        providerLimit: Int = 5
    ) -> [Self] {
        var sections: [Self] = []
        let models = models.filter { $0.category == .llm }
        let availableModelIDs = Set(models.map(\.id))
        let visibleRecentModels = Array(
            recentModels.lazy
                .filter {
                    availableModelIDs.contains($0.id)
                        && $0.id != selectedModelID
                }
                .prefix(max(0, recentLimit))
        )
        if !visibleRecentModels.isEmpty {
            sections.append(
                Self(id: .recent, title: "Recent", models: visibleRecentModels)
            )
        }

        let orderedProviders = displayProviders(from: models, providerOrder: providerOrder)
        for provider in orderedProviders {
            let providerModels = Array(
                models.lazy
                    .filter {
                        $0.displayProvider == provider
                            && $0.capabilities.isRecommendedInChatPicker
                    }
                    .prefix(max(0, providerLimit))
            )
            guard !providerModels.isEmpty else { continue }
            sections.append(
                Self(
                    id: provider == .amazonBedrock ? .bedrock : .provider(provider.provider),
                    title: provider.displayName,
                    models: providerModels
                )
            )
        }
        return sections
    }

    public static func displayProviders(
        from models: [ChatModelOption],
        providerOrder: [AIProviderKind]
    ) -> [AIProviderPreset] {
        var seen: Set<AIProviderPreset> = []
        let models = models.filter { $0.category == .llm }
        return (providerOrder + AIProviderKind.allCases).flatMap { provider in
            models.filter { $0.provider == provider }.map(\.displayProvider)
        }.filter { seen.insert($0).inserted }
    }
}
