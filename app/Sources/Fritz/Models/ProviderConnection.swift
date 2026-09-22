import Foundation

enum AIProviderKind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case openAI = "openai"
    case openAICompatible = "openai-compatible"
    case openRouter = "openrouter"
    case anthropic, gemini, ollama, fritz
    var id: String { rawValue }
    var name: String {
        switch self {
        case .openAI: "OpenAI"
        case .openAICompatible: "OpenAI-compatible"
        case .openRouter: "OpenRouter"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .ollama: "Ollama"
        case .fritz: "Fritz"
        }
    }
    var requiresAPIKey: Bool { self != .openAICompatible && self != .ollama && self != .fritz }
    var systemImage: String {
        switch self {
        case .openAI: "sparkles"
        case .openAICompatible: "network"
        case .openRouter: "arrow.triangle.branch"
        case .anthropic: "text.bubble"
        case .gemini: "diamond"
        case .ollama: "desktopcomputer"
        case .fritz: "cpu"
        }
    }
    var endpoint: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .openAICompatible: ""
        case .openRouter: "https://openrouter.ai/api/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        case .ollama: "http://localhost:11434"
        case .fritz: ""
        }
    }
}

struct ProviderConnection: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var provider: AIProviderKind
    var baseURL: String?
    var modelID = ""
    enum CodingKeys: String, CodingKey {
        case id, name, provider
        case baseURL = "baseUrl"
        case modelID = "modelId"
    }
    var providerDisplayName: String {
        AIProviderPreset.matching(provider: provider, baseURL: baseURL).displayName
    }
}

struct ProviderRegistry: Codable, Sendable {
    var version = 1
    var connections: [ProviderConnection] = []
    var defaultConnectionId: UUID?
}

struct DiscoveredAIModel: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    var createdAt: UInt64? { nil }
    var verification: AIModelVerification { .unverified }
}
struct ModelCatalog: Decodable { let models: [DiscoveredAIModel] }
enum AIModelVerification: String, Codable, Sendable { case unverified, compatible }
enum ChatReasoningEffort: String, CaseIterable, Codable, Identifiable, Sendable {
    case low, medium, high
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}
enum ChatSpeed: String, CaseIterable, Codable, Identifiable, Sendable {
    case standard, priority, flex
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}
