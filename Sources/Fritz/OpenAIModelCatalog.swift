import Foundation

/// Reviewed API capabilities shared with the Rust request builder.
public enum OpenAIModelCatalog {
    public enum Status: String, Decodable, Sendable {
        case active, deprecated, retired
    }

    struct Entry: Decodable, Sendable {
        let displayName: String
        let reasoningEfforts: [ChatReasoningEffort]
        let speeds: [ChatSpeed]
        let status: Status
        let defaultReasoning: ChatReasoningEffort?
        let defaultSpeed: ChatSpeed

        private enum CodingKeys: CodingKey {
            case displayName, reasoningEfforts, speeds, status, defaultReasoning, defaultSpeed
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            displayName = try values.decode(String.self, forKey: .displayName)
            reasoningEfforts = try values.decode([ChatReasoningEffort].self, forKey: .reasoningEfforts)
            speeds = try values.decode([ChatSpeed].self, forKey: .speeds)
            status = try values.decode(Status.self, forKey: .status)
            // Required key; null means this model has no configurable reasoning.
            defaultReasoning = try values.decode(ChatReasoningEffort?.self, forKey: .defaultReasoning)
            defaultSpeed = try values.decode(ChatSpeed.self, forKey: .defaultSpeed)
            guard !displayName.isEmpty, speeds.contains(defaultSpeed),
                  defaultReasoning.map({ reasoningEfforts.contains($0) }) ?? reasoningEfforts.isEmpty else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "Model defaults must be supported capabilities"))
            }
        }
    }

    private struct Catalog: Decodable {
        let schemaVersion: Int
        let revision: Int
        let models: [String: Entry]
    }
    private struct RootCatalog: Decodable { let reviewed_openai: Catalog }

    private static let models: [String: Entry] = {
        guard let url = Bundle.module.url(forResource: "ModelCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(RootCatalog.self, from: data).reviewed_openai,
              catalog.schemaVersion == 1, catalog.revision > 0, !catalog.models.isEmpty else {
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
