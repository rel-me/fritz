import Foundation

public struct ChatModelOption: Codable, Equatable, Identifiable, Sendable {
    public enum Source: Codable, Equatable, Sendable {
        case builtIn
        case configured
    }

    public struct Capabilities: Codable, Equatable, Sendable {
        public let supportsReasoningEffort: Bool
        public let supportedSpeeds: [ChatSpeed]
        public let isRecommendedInChatPicker: Bool

        public init(supportsReasoningEffort: Bool, supportedSpeeds: [ChatSpeed], isRecommendedInChatPicker: Bool) {
            self.supportsReasoningEffort = supportsReasoningEffort
            self.supportedSpeeds = supportedSpeeds
            self.isRecommendedInChatPicker = isRecommendedInChatPicker
        }

        public var supportsSpeed: Bool {
            supportedSpeeds.count > 1
        }

        public static func inferred(provider: AIProviderKind, modelID: String) -> Self {
            let modelID = modelID.lowercased()
            let isSpecializedModel = [
                "audio", "computer-use", "dall-e", "embed", "guard", "image",
                "live", "moderation", "realtime", "rerank", "search-preview", "sora",
                "speech", "transcribe", "tts", "video", "whisper",
            ].contains { modelID.contains($0) }
            guard provider == .openAI else {
                return Self(
                    supportsReasoningEffort: false,
                    supportedSpeeds: [.standard],
                    isRecommendedInChatPicker: !isSpecializedModel
                )
            }

            let hasFixedReasoningEffort = modelID.contains("-pro")
                || modelID.contains("deep-research")
            let isReasoningModel = modelID.hasPrefix("gpt-5")
                || Self.hasOSeriesPrefix(modelID)
            let isConfigurableReasoningModel = isReasoningModel
                && !hasFixedReasoningEffort
                && !isSpecializedModel
                && !modelID.contains("-chat")
            let canChooseServiceTier = !hasFixedReasoningEffort
                && !isSpecializedModel
                && !modelID.contains("-chat")
            let supportsPrioritySpeed = canChooseServiceTier
                && (modelID.hasPrefix("gpt-5")
                    || modelID.hasPrefix("gpt-4.1")
                    || modelID.hasPrefix("gpt-4o")
                    || modelID == "o3"
                    || modelID.hasPrefix("o3-")
                    || modelID == "o4-mini"
                    || modelID.hasPrefix("o4-mini-"))
            let supportsFlexSpeed = canChooseServiceTier
                && ((modelID.hasPrefix("gpt-5") && !modelID.contains("-codex"))
                || modelID == "o3"
                || modelID.hasPrefix("o3-")
                || modelID == "o4-mini"
                || modelID.hasPrefix("o4-mini-"))
            var supportedSpeeds: [ChatSpeed] = [.standard]
            if supportsPrioritySpeed {
                supportedSpeeds.append(.priority)
            }
            if supportsFlexSpeed {
                supportedSpeeds.append(.flex)
            }

            return Self(
                supportsReasoningEffort: isConfigurableReasoningModel,
                supportedSpeeds: supportedSpeeds,
                isRecommendedInChatPicker: !isSpecializedModel
            )
        }

        public var reasoningEfforts: [ChatReasoningEffort] {
            supportsReasoningEffort ? [.low, .medium, .high] : []
        }

        private static func hasOSeriesPrefix(_ modelID: String) -> Bool {
            guard modelID.first == "o",
                  let series = modelID.dropFirst().first,
                  series.isNumber else {
                return false
            }
            return true
        }
    }

    public let id: String
    public let displayName: String
    public let provider: AIProviderKind
    public let modelID: String
    public let connectionName: String?
    public let connectionID: UUID?
    public let source: Source
    public let createdAt: UInt64?
    public let verification: AIModelVerification
    public let capabilities: Capabilities
    public let displayProvider: AIProviderPreset

    public var usageKey: String {
        "\(provider.rawValue):\(modelID.lowercased())"
    }

    public init(
        id: String,
        displayName: String,
        provider: AIProviderKind,
        modelID: String,
        connectionName: String? = nil,
        connectionID: UUID? = nil,
        source: Source = .builtIn,
        createdAt: UInt64? = nil,
        verification: AIModelVerification = .unverified,
        capabilities: Capabilities? = nil,
        baseURL: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
        self.modelID = modelID
        self.connectionName = connectionName
        self.connectionID = connectionID
        self.source = source
        self.createdAt = createdAt
        self.verification = verification
        self.capabilities = capabilities ?? .inferred(provider: provider, modelID: modelID)
        self.displayProvider = AIProviderPreset.displayProvider(provider: provider, baseURL: baseURL)
    }

    public init(connection: ProviderConnection) {
        self.init(
            id: "connection:\(connection.id.uuidString):\(connection.modelID)",
            displayName: connection.modelID,
            provider: connection.provider,
            modelID: connection.modelID,
            connectionName: connection.name,
            connectionID: connection.id,
            source: .configured,
            baseURL: connection.baseURL
        )
    }

    public init(connection: ProviderConnection, model: DiscoveredAIModel) {
        self.init(
            id: "connection:\(connection.id.uuidString):\(model.id)",
            displayName: model.displayName,
            provider: connection.provider,
            modelID: model.id,
            connectionName: connection.name,
            connectionID: connection.id,
            source: .configured,
            createdAt: model.createdAt,
            verification: model.verification,
            baseURL: connection.baseURL
        )
    }

    public static func balancedPickerRecommendations(
        from options: [Self],
        providerOrder: [AIProviderKind],
        selectedModelID: String?,
        limit: Int
    ) -> [Self] {
        guard limit > 0 else { return [] }

        let selectedModel = selectedModelID.flatMap { selectedModelID in
            options.first { $0.id == selectedModelID }
        }
        var recommendations = selectedModel.map { [$0] } ?? []
        guard recommendations.count < limit else { return recommendations }

        let availableProviders = Set(options.map(\.provider))
        var seenProviders: Set<AIProviderKind> = []
        let orderedProviders = (providerOrder + AIProviderKind.allCases).filter { provider in
            availableProviders.contains(provider) && seenProviders.insert(provider).inserted
        }
        let recommendedByProvider = Dictionary(
            grouping: options.filter { option in
                option.id != selectedModelID
                    && option.capabilities.isRecommendedInChatPicker
            },
            by: \.provider
        )
        var nextIndexByProvider: [AIProviderKind: Int] = [:]

        func appendNextRecommendation(for provider: AIProviderKind) -> Bool {
            let nextIndex = nextIndexByProvider[provider, default: 0]
            guard let providerModels = recommendedByProvider[provider],
                  nextIndex < providerModels.count else {
                return false
            }
            recommendations.append(providerModels[nextIndex])
            nextIndexByProvider[provider] = nextIndex + 1
            return true
        }

        for provider in orderedProviders where provider != selectedModel?.provider {
            guard recommendations.count < limit else { return recommendations }
            _ = appendNextRecommendation(for: provider)
        }

        while recommendations.count < limit {
            var appendedRecommendation = false
            for provider in orderedProviders {
                guard recommendations.count < limit else { return recommendations }
                appendedRecommendation = appendNextRecommendation(for: provider)
                    || appendedRecommendation
            }
            guard appendedRecommendation else { break }
        }
        return recommendations
    }
}

