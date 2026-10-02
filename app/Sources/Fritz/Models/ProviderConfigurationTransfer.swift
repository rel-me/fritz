import Foundation
import Fritz

enum ExistingProviderImportPolicy: String, CaseIterable {
    case skip, overwrite
}

enum ProviderConfigurationTransfer {
    static let maximumBytes = 1_048_576

    struct TransferError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Envelope<Value: Codable>: Codable {
        let format: String
        let version: Int
        let configuration: Value
    }

    struct Configuration: Codable {
        var name: String
        var baseURL: String?
        var modelID: String?
        var apiKey: String?

        init(_ connection: ProviderConnection, apiKey: String? = nil) {
            name = AIProviderPreset.matching(provider: connection.provider, baseURL: connection.baseURL).name
            baseURL = connection.baseURL
            modelID = connection.modelID.isEmpty ? nil : connection.modelID
            self.apiKey = apiKey
        }

        func connection() throws -> ProviderConnection {
            // Accept REL's service label and its older Jev label.
            let service = ["Jev", "TypeSafe AI"].contains(name) ? "TypeSafe" : name
            guard let preset = AIProviderPreset.allCases.first(where: { $0.name == service }) else {
                throw TransferError(message: "Unknown provider service. Choose a supported service.")
            }
            guard AIProviderPreset.matching(provider: preset.provider, baseURL: baseURL) == preset else {
                throw TransferError(message: "The base URL does not match the provider service.")
            }
            return ProviderConnection(name: service, provider: preset.provider, baseURL: baseURL,
                                      modelID: modelID ?? (preset.provider == .jev ? "jev-latest" : ""))
        }
    }

    struct ImportItem: Encodable {
        let connection: ProviderConnection
        let apiKey: String?
    }

    static func exportCURL(_ configurations: [Configuration]) throws -> String {
        guard !configurations.isEmpty else { throw TransferError(message: "Select at least one provider to export.") }
        let commands = try configurations.map { configuration in
            let connection = try configuration.connection()
            guard !connection.provider.isNative else {
                throw TransferError(message: "This selection contains local model connections without an HTTP endpoint. Select only HTTP providers to export cURL.")
            }
            let base = (connection.baseURL?.isEmpty == false ? connection.baseURL! : connection.provider.endpoint)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !base.isEmpty else { throw TransferError(message: "Add a Gateway URL before exporting cURL.") }
            let model = connection.modelID.isEmpty ? "MODEL_ID" : connection.modelID
            let messages: [[String: String]] = [["role": "user", "content": "Hello"]]
            let endpoint: String
            let body: [String: Any]
            switch connection.provider {
            case .openAI:
                endpoint = base + "/responses"
                body = ["model": model, "input": messages, "store": false]
            case .anthropic:
                endpoint = base + "/messages"
                body = ["model": model, "messages": messages, "max_tokens": 1024]
            case .gemini:
                let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
                let modelPath = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
                guard let encoded = modelPath.addingPercentEncoding(withAllowedCharacters: allowed) else {
                    throw TransferError(message: "The model ID cannot be used in a cURL URL.")
                }
                endpoint = base + "/models/" + encoded + ":generateContent"
                body = ["contents": [["role": "user", "parts": [["text": "Hello"]]]]]
            case .ollama:
                endpoint = base + "/api/chat"
                body = ["model": model, "messages": messages, "stream": false]
            case .jev:
                endpoint = base
                body = ["model": model, "state": ["message": "Remind me tomorrow"],
                        "questions": ["reminder": ["type": "noul", "instructions": "Does the message request a reminder?"]]]
            case .openRouter, .openAICompatible:
                endpoint = base + "/chat/completions"
                body = ["model": model, "messages": messages]
            case .fritz, .ollaya:
                throw TransferError(message: "Local model connections without an HTTP endpoint cannot be exported as cURL.")
            }
            var headers = ["Content-Type: application/json"]
            if connection.provider == .anthropic { headers.append("anthropic-version: 2023-06-01") }
            let key = configuration.apiKey.flatMap { $0.isEmpty ? nil : $0 }
            guard key?.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) != true else {
                throw TransferError(message: "The API key contains invalid control characters.")
            }
            if key != nil || connection.provider != .ollama {
                let header = switch connection.provider {
                case .anthropic: "x-api-key"
                case .gemini: "x-goog-api-key"
                default: "Authorization"
                }
                let value = (header == "Authorization" ? "Bearer " : "") + (key ?? "YOUR_API_KEY")
                headers.append(header + ": " + value)
            }
            let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
            // A quoted heredoc prevents shell expansion; stdin keeps keys out of process arguments.
            let options = ["url = " + curlQuoted(endpoint), "request = \"POST\""]
                + headers.map { "header = " + curlQuoted($0) }
                + ["data = " + curlQuoted(String(decoding: data, as: UTF8.self))]
            return "curl -q --globoff --silent --show-error --fail-with-body --config - <<'CURL_CONFIG'\n"
                + options.joined(separator: "\n") + "\nCURL_CONFIG"
        }
        let text = commands.joined(separator: "\n\n")
        try checkSize(text.utf8.count)
        return text
    }

    private static func curlQuoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r") + "\""
    }

    static func decode(_ text: String) throws -> [Configuration] {
        try checkSize(text.utf8.count)
        let data = Data(text.utf8)
        struct Header: Decodable { let format: String; let version: Int }
        do {
            let header = try JSONDecoder().decode(Header.self, from: data)
            guard header.version == 1 else { throw TransferError(message: "Use a version 1 provider configuration.") }
            let configurations: [Configuration]
            switch header.format {
            case "fritz.provider", "rel.provider":
                configurations = [try JSONDecoder().decode(Envelope<Configuration>.self, from: data).configuration]
            case "fritz.providers", "rel.providers":
                configurations = try JSONDecoder().decode(Envelope<[Configuration]>.self, from: data).configuration
            default:
                throw TransferError(message: "Paste a provider configuration.")
            }
            guard !configurations.isEmpty else { throw TransferError(message: "The provider list is empty.") }
            for configuration in configurations { _ = try configuration.connection() }
            return configurations
        } catch let error as TransferError {
            throw error
        } catch {
            throw TransferError(message: "Invalid provider JSON. Copy the complete exported configuration and try again.")
        }
    }

    static func plan(_ configurations: [Configuration], existing: [ProviderConnection],
                     policy: ExistingProviderImportPolicy) throws -> [ImportItem] {
        var connections = existing
        var result: [ImportItem] = []
        for configuration in configurations {
            var connection = try configuration.connection()
            let preset = AIProviderPreset.matching(provider: connection.provider, baseURL: connection.baseURL)
            let matches = connections.filter { AIProviderPreset.matching(provider: $0.provider, baseURL: $0.baseURL) == preset }
            if !matches.isEmpty, policy == .skip { continue }
            guard matches.count <= 1 else {
                throw TransferError(message: "Multiple connections use \(preset.name). Remove duplicate connections before overwriting this service.")
            }
            if let previous = matches.first {
                connection.id = previous.id
                connection.name = previous.name
            } else {
                var suffix = 2
                while connections.contains(where: { $0.name.caseInsensitiveCompare(connection.name) == .orderedSame }) {
                    connection.name = "\(preset.name) \(suffix)"
                    suffix += 1
                }
            }
            // Repeated services in a list use the same Skip/Overwrite policy.
            connections.removeAll { $0.id == connection.id }
            connections.append(connection)
            result.append(ImportItem(connection: connection, apiKey: configuration.apiKey))
        }
        return result
    }

    private static func checkSize(_ count: Int) throws {
        if count > maximumBytes { throw TransferError(message: "The configuration must be no larger than 1 MB.") }
    }
}
