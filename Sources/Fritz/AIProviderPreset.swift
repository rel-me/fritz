import Foundation

/// Editor presets configure existing adapters without adding wire-protocol provider kinds.
public enum AIProviderPreset: Codable, Hashable, Identifiable, Sendable {
    case adapter(AIProviderKind)
    case fireworks
    case amazonBedrock
    case baseten

    public static let allCases: [Self] = AIProviderKind.allCases.map(Self.adapter)
        + [.fireworks, .amazonBedrock, .baseten]

    public var id: String {
        switch self {
        case .adapter(let kind): kind.rawValue
        case .fireworks: "fireworks"
        case .amazonBedrock: "amazon-bedrock"
        case .baseten: "baseten"
        }
    }

    public var connectionName: String? {
        if case .adapter = self { return nil }
        return id
    }

    public var name: String {
        switch self {
        case .adapter(let kind): kind.name
        case .fireworks: "Fireworks"
        case .amazonBedrock: "Amazon Bedrock"
        case .baseten: "Baseten"
        }
    }

    public var provider: AIProviderKind {
        if case .adapter(let kind) = self { return kind }
        return .openAICompatible
    }

    public var displayName: String {
        self == .amazonBedrock ? "Bedrock" : name
    }

    public static func displayProvider(provider: AIProviderKind, baseURL: String?) -> Self {
        matching(provider: provider, baseURL: baseURL) == .amazonBedrock
            ? .amazonBedrock : .adapter(provider)
    }

    public var requiresAPIKey: Bool {
        if case .adapter(let kind) = self { return kind.requiresAPIKey }
        return true
    }

    public var baseURL: String {
        switch self {
        case .adapter: ""
        case .fireworks: "https://api.fireworks.ai/inference/v1"
        case .amazonBedrock: "https://bedrock-mantle.us-east-1.api.aws/v1"
        case .baseten: "https://inference.baseten.co/v1"
        }
    }

    public static func matching(provider: AIProviderKind, baseURL: String?) -> Self {
        guard provider == .openAICompatible,
              let url = URL(string: baseURL ?? ""), url.scheme == "https" else {
            return .adapter(provider)
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if url.host == "api.fireworks.ai", path == "inference/v1" { return .fireworks }
        if url.host == "inference.baseten.co", path == "v1" { return .baseten }
        if let host = url.host, host.hasPrefix("bedrock-mantle."),
           host.hasSuffix(".api.aws"), path == "v1" { return .amazonBedrock }
        return .adapter(provider)
    }
}

public enum AIProviderCategory: String, CaseIterable, Identifiable {
    case all = "All"
    case local = "Local"
    case remote = "Remote"
    case frontier = "Frontier"
    case hosted = "Hosted"
    case custom = "Custom"

    public var id: Self { self }

    public func contains(_ preset: AIProviderPreset) -> Bool {
        switch self {
        case .all: true
        case .local: [.fritz, .ollama].contains(preset.provider)
        case .remote: !AIProviderCategory.local.contains(preset)
        case .frontier: [.openAI, .anthropic, .gemini].contains(preset.provider)
        case .hosted: [.adapter(.openRouter), .fireworks, .amazonBedrock, .baseten].contains(preset)
        case .custom: preset == .adapter(.openAICompatible)
        }
    }

    public var help: String {
        switch self {
        case .all: "Show all providers"
        case .local: "Fritz and Ollama"
        case .remote: "Remote services and configurable API endpoints"
        case .frontier: "OpenAI, Anthropic, and Google Gemini"
        case .hosted: "OpenRouter, Fireworks, Amazon Bedrock, and Baseten"
        case .custom: "Configure an OpenAI-compatible endpoint"
        }
    }
}
