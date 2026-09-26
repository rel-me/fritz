import Foundation

public enum AIModelCategory: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case llm
    case decision

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .llm: "LLMs"
        case .decision: "Decision Models"
        }
    }
}

public enum AIProviderKind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case openAI = "openai"
    case openAICompatible = "openai-compatible"
    case openRouter = "openrouter"
    case anthropic, gemini, ollama, fritz, jev
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .openAI: "OpenAI"
        case .openAICompatible: "OpenAI-compatible"
        case .openRouter: "OpenRouter"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .ollama: "Ollama"
        case .fritz: "Fritz"
        case .jev: "TypeSafe"
        }
    }
    public var requiresAPIKey: Bool { self != .openAICompatible && self != .ollama && self != .fritz }
    public var category: AIModelCategory { self == .jev ? .decision : .llm }
    public var systemImage: String {
        switch self {
        case .openAI: "sparkles"
        case .openAICompatible: "network"
        case .openRouter: "arrow.triangle.branch"
        case .anthropic: "text.bubble"
        case .gemini: "diamond"
        case .ollama: "desktopcomputer"
        case .fritz: "cpu"
        case .jev: "checkmark.seal"
        }
    }
    public var endpoint: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .openAICompatible: ""
        case .openRouter: "https://openrouter.ai/api/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        case .ollama: "http://localhost:11434"
        case .fritz: ""
        case .jev: "https://api.typesafe.ai/v1/systemone"
        }
    }
}

public struct ProviderConnection: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var provider: AIProviderKind
    public var baseURL: String?
    public var modelID = ""
    public init(id: UUID = UUID(), name: String, provider: AIProviderKind, baseURL: String? = nil, modelID: String = "") {
        self.id = id
        self.name = name
        self.provider = provider
        self.baseURL = baseURL
        self.modelID = modelID
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, provider
        case baseURL = "baseUrl"
        case modelID = "modelId"
    }
    public var providerDisplayName: String {
        AIProviderPreset.matching(provider: provider, baseURL: baseURL).displayName
    }
    public var category: AIModelCategory { provider.category }
}

public struct ProviderRegistry: Codable, Sendable {
    public var version = 1
    public var connections: [ProviderConnection] = []
    public var defaultConnectionId: UUID?
    public init(version: Int = 1, connections: [ProviderConnection] = [], defaultConnectionId: UUID? = nil) {
        self.version = version
        self.connections = connections
        self.defaultConnectionId = defaultConnectionId
    }
}

public struct DiscoveredAIModel: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
    public var createdAt: UInt64? { nil }
    public var verification: AIModelVerification { .unverified }
}
public struct ModelCatalog: Decodable { public let models: [DiscoveredAIModel] }
public enum AIModelVerification: String, Codable, Sendable { case unverified, compatible }
public enum ChatReasoningEffort: String, CaseIterable, Codable, Identifiable, Sendable {
    case low, medium, high
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}
public enum ChatSpeed: String, CaseIterable, Codable, Identifiable, Sendable {
    case standard, priority, flex
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}
