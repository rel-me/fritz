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
                throw TransferError(message: "Unknown provider service. Use a service supported by Fritz.")
            }
            guard AIProviderPreset.matching(provider: preset.provider, baseURL: baseURL) == preset else {
                throw TransferError(message: "The base URL does not match the provider service.")
            }
            return ProviderConnection(name: service, provider: preset.provider, baseURL: baseURL,
                                      modelID: modelID ?? (preset.category == .decision ? "jev-latest" : ""))
        }
    }

    struct ImportItem: Encodable {
        let connection: ProviderConnection
        let apiKey: String?
    }

    static func export(_ configurations: [Configuration]) throws -> String {
        guard !configurations.isEmpty else { throw TransferError(message: "Select at least one provider to export.") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = configurations.count == 1
            ? try encoder.encode(Envelope(format: "fritz.provider", version: 1, configuration: configurations[0]))
            : try encoder.encode(Envelope(format: "fritz.providers", version: 1, configuration: configurations))
        try checkSize(data.count)
        return String(decoding: data, as: UTF8.self)
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
                throw TransferError(message: "Paste a Fritz or REL provider configuration.")
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
