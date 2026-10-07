import Foundation

/// Reviewed API capabilities shared with the Rust request builder.
public enum OpenAIModelCatalog {
    struct Entry: Decodable, Sendable {
        let displayName: String
        let reasoningEfforts: [ChatReasoningEffort]
        let speeds: [ChatSpeed]
    }

    private struct Catalog: Decodable {
        let version: Int
        let models: [String: Entry]
    }

    private static let models: [String: Entry] = {
        guard let url = Bundle.module.url(forResource: "OpenAIModels", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
              catalog.version == 1, !catalog.models.isEmpty else {
            preconditionFailure("Missing or invalid bundled OpenAI model catalog")
        }
        return catalog.models
    }()

    static func entry(for modelID: String) -> Entry? { models[modelID.lowercased()] }

    public static func displayName(modelID: String, fallback: String) -> String {
        // Keep names supplied by the provider or host. Formatting never changes the API ID.
        guard fallback == modelID else { return fallback }
        if let entry = entry(for: modelID) { return entry.displayName }
        let parts = modelID.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "gpt", parts[1].first?.isNumber == true else { return fallback }
        let suffix = parts.dropFirst(2).map { $0.capitalized }.joined(separator: " ")
        return "GPT-\(parts[1])" + (suffix.isEmpty ? "" : " \(suffix)")
    }
}
