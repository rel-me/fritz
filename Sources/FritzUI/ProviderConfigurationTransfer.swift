import Foundation
import Fritz

enum ProviderConfigurationTransfer {
    static let maximumBytes = 1_048_576

    struct TransferError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Configuration {
        let connection: ProviderConnection
        let apiKey: String?

        init(_ connection: ProviderConnection, apiKey: String? = nil) {
            self.connection = connection
            self.apiKey = apiKey
        }
    }

    struct ImportItem: Encodable {
        let connection: ProviderConnection
        let apiKey: String?
    }

    static func exportCURL(_ configurations: [Configuration]) throws -> String {
        guard !configurations.isEmpty else { throw TransferError(message: "Select at least one provider to export.") }
        let commands = try configurations.map { configuration in
            let connection = configuration.connection
            guard !connection.provider.isNative else {
                throw TransferError(message: "This selection contains local model connections without an HTTP endpoint. Select only HTTP providers to export cURL.")
            }
            let base = connection.baseURL.flatMap { $0.isEmpty ? nil : $0 } ?? connection.provider.endpoint
            let url = try checkedURL(base)
            let endpoint: URL
            switch connection.provider {
            case .ollama: endpoint = url.appendingPathComponent("api/tags")
            case .jev: endpoint = url.deletingLastPathComponent().appendingPathComponent("models")
            default: endpoint = url.appendingPathComponent("models")
            }
            var headers: [String] = []
            if connection.provider == .anthropic { headers.append("anthropic-version: 2023-06-01") }
            let key = configuration.apiKey.flatMap { $0.isEmpty ? nil : $0 }
            try checkCredential(key)
            let preset = AIProviderPreset.matching(provider: connection.provider, baseURL: connection.baseURL)
            if key != nil || preset.requiresAPIKey {
                let header = switch connection.provider {
                case .anthropic: "x-api-key"
                case .gemini: "x-goog-api-key"
                default: "Authorization"
                }
                let value = (header == "Authorization" ? "Bearer " : "") + (key ?? "YOUR_API_KEY")
                headers.append(header + ": " + value)
            }
            // cURL ignores these comments; import uses them to preserve connection settings.
            let options = ["# provider = " + curlQuoted(connection.provider.rawValue),
                           "# name = " + curlQuoted(connection.name),
                           "# model = " + curlQuoted(connection.modelID),
                           "url = " + curlQuoted(endpoint.absoluteString), "request = \"GET\""]
                + headers.map { "header = " + curlQuoted($0) }
            // A quoted heredoc prevents shell expansion; stdin keeps keys out of process arguments.
            return "curl -q --globoff --silent --show-error --fail-with-body --connect-timeout 15 --max-time 30 --config - <<'CURL_CONFIG'\n"
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

    /// Parse data only. Imported shell text is never executed or expanded.
    static func decode(_ text: String) throws -> [Configuration] {
        try checkSize(text.utf8.count)
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        var configurations: [Configuration] = []
        while index < lines.count {
            var command = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            if command.isEmpty || command.hasPrefix("#") { continue }
            while command.hasSuffix("\\"), index < lines.count {
                command.removeLast()
                command += " " + lines[index].trimmingCharacters(in: .whitespaces)
                index += 1
            }
            var request = CURLRequest()
            let delimiter = "<<'CURL_CONFIG'"
            if command.hasSuffix(delimiter) {
                let tokens = try shellWords(String(command.dropLast(delimiter.count)))
                try request.readArguments(tokens, config: true)
                var closed = false
                while index < lines.count {
                    let line = lines[index].trimmingCharacters(in: .whitespaces)
                    index += 1
                    if line == "CURL_CONFIG" { closed = true; break }
                    if line.isEmpty { continue }
                    try request.readConfig(line)
                }
                guard closed else { throw invalidCURL() }
            } else {
                try request.readArguments(shellWords(command), config: false)
            }
            configurations.append(try request.configuration())
        }
        guard !configurations.isEmpty else { throw invalidCURL() }
        return configurations
    }

    private struct CURLRequest {
        var url: String?
        var method = "GET"
        var headers: [String] = []
        var metadata: [String: String] = [:]

        mutating func readArguments(_ words: [String], config: Bool) throws {
            guard words.first == "curl" else { throw invalidCURL() }
            var index = 1
            var readsConfig = false
            while index < words.count {
                let option = words[index]
                index += 1
                switch option {
                case "-q", "--disable", "--globoff", "-s", "--silent", "-S", "--show-error", "--fail-with-body", "-f", "--fail": break
                case "--config", "-K":
                    guard config, index < words.count, words[index] == "-", !readsConfig else { throw invalidCURL() }
                    readsConfig = true; index += 1
                case "--connect-timeout", "--max-time", "-m":
                    guard index < words.count, let value = Double(words[index]), value.isFinite, value > 0 else { throw invalidCURL() }
                    index += 1
                case "--url", "-X", "--request", "-H", "--header":
                    guard index < words.count else { throw invalidCURL() }
                    let value = words[index]; index += 1
                    if option == "--url" { try setURL(value) }
                    else if option == "-X" || option == "--request" { method = value }
                    else { headers.append(value) }
                default:
                    guard !option.hasPrefix("-"), !config else { throw invalidCURL() }
                    try setURL(option)
                }
            }
            guard readsConfig == config else { throw invalidCURL() }
        }

        mutating func setURL(_ value: String) throws {
            guard url == nil else { throw invalidCURL() }
            url = value
        }

        mutating func readConfig(_ line: String) throws {
            let isComment = line.hasPrefix("#")
            let value = isComment ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces) : line
            guard let separator = value.firstIndex(of: "=") else {
                if isComment { return }
                throw invalidCURL()
            }
            let option = value[..<separator].trimmingCharacters(in: .whitespaces)
            if isComment, !["provider", "name", "model"].contains(option) { return }
            let parameter = try configValue(String(value[value.index(after: separator)...]).trimmingCharacters(in: .whitespaces))
            if isComment {
                guard metadata[option] == nil else { throw invalidCURL() }
                metadata[option] = parameter
            } else {
                switch option {
                case "url": try setURL(parameter)
                case "request": method = parameter
                case "header": headers.append(parameter)
                default: throw invalidCURL()
                }
            }
        }

        func configuration() throws -> Configuration {
            guard let url, method.uppercased() == "GET" else { throw invalidCURL() }
            let endpoint = try checkedURL(url)
            var key: String?
            var authHeader: String?
            for header in headers {
                guard let colon = header.firstIndex(of: ":") else { throw invalidCURL() }
                let name = header[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                switch name {
                case "authorization", "x-api-key", "x-goog-api-key":
                    guard authHeader == nil else { throw invalidCURL() }
                    authHeader = name
                    if name == "authorization" {
                        guard value.lowercased().hasPrefix("bearer ") else { throw invalidCURL() }
                        key = String(value.dropFirst(7))
                    } else { key = value }
                case "anthropic-version", "accept", "content-type": break
                default: throw TransferError(message: "This cURL request uses an unsupported header. Import a provider check request with its API key header.")
                }
            }
            try checkCredential(key)
            let provider: AIProviderKind
            if let raw = metadata["provider"] {
                guard let kind = AIProviderKind(rawValue: raw), !kind.isNative else { throw invalidCURL() }
                provider = kind
            } else if endpoint.path.hasSuffix("/api/tags") { provider = .ollama }
            else if authHeader == "x-api-key" { provider = .anthropic }
            else if authHeader == "x-goog-api-key" { provider = .gemini }
            else {
                provider = AIProviderKind.allCases.first { kind in
                    !kind.isNative && kind != .openAICompatible && URL(string: kind.endpoint)?.host == endpoint.host
                } ?? .openAICompatible
            }
            let expectedHeader = provider == .anthropic ? "x-api-key" : provider == .gemini ? "x-goog-api-key" : "authorization"
            guard authHeader == nil || authHeader == expectedHeader else { throw invalidCURL() }
            let base: URL
            if provider == .ollama, endpoint.path.hasSuffix("/api/tags") {
                base = endpoint.deletingLastPathComponent().deletingLastPathComponent()
            } else if endpoint.path.hasSuffix("/models") || endpoint.path.hasSuffix("/health") {
                base = endpoint.deletingLastPathComponent()
            } else { throw TransferError(message: "Use a cURL GET request to a models, api/tags, or health endpoint.") }
            let baseURL: String?
            if provider == .jev {
                guard base.appendingPathComponent("systemone").absoluteString == provider.endpoint else { throw invalidCURL() }
                baseURL = nil
            } else {
                baseURL = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
            }
            let preset = AIProviderPreset.matching(provider: provider, baseURL: baseURL)
            let model = metadata["model"] ?? (provider == .jev ? "jev-latest" : "")
            guard provider != .jev || model.isEmpty || model == "jev-latest" else { throw invalidCURL() }
            let name = metadata["name"] ?? preset.name
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalidCURL() }
            return Configuration(ProviderConnection(name: name, provider: provider, baseURL: baseURL, modelID: model),
                                 apiKey: key == "YOUR_API_KEY" || key?.isEmpty == true ? nil : key)
        }
    }

    private static func checkedURL(_ text: String) throws -> URL {
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: text),
              let url = components.url, let host = components.host, !host.isEmpty,
              ["https", "http"].contains(components.scheme),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.scheme == "https" || ["localhost", "127.0.0.1", "[::1]"].contains(host) else {
            throw TransferError(message: "Use an HTTPS endpoint, or HTTP for a local service, without URL credentials, a query, or a fragment.")
        }
        return url
    }

    private static func checkCredential(_ key: String?) throws {
        guard key?.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) != true else {
            throw TransferError(message: "The API key contains invalid control characters.")
        }
    }

    private static func configValue(_ text: String) throws -> String {
        guard text.first == "\"" else { throw invalidCURL() }
        var value = ""
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]; index = text.index(after: index)
            if character == "\"" {
                guard index == text.endIndex else { throw invalidCURL() }
                return value
            }
            if character == "\\" {
                guard index < text.endIndex else { throw invalidCURL() }
                let escaped = text[index]; index = text.index(after: index)
                switch escaped {
                case "\\", "\"": value.append(escaped)
                case "t": value.append("\t")
                case "n": value.append("\n")
                case "r": value.append("\r")
                case "v": value.append("\u{0B}")
                default: throw invalidCURL()
                }
            } else { value.append(character) }
        }
        throw invalidCURL()
    }

    private static func shellWords(_ text: String) throws -> [String] {
        var words: [String] = []
        var word = ""
        var started = false
        var quote: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]; index = text.index(after: index)
            if quote == "'" {
                if character == "'" { quote = nil } else { word.append(character) }
            } else if character == "\\" {
                guard index < text.endIndex else { throw invalidCURL() }
                let escaped = text[index]; index = text.index(after: index)
                if quote == "\"", !["\\", "\"", "$", "`"].contains(escaped) { word.append("\\") }
                word.append(escaped); started = true
            } else if character == "\"" || character == "'" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character; started = true }
                else { word.append(character) }
            } else if character == "$" || character == "`" || (quote == nil && ";|&<>".contains(character)) {
                throw invalidCURL()
            } else if character.isWhitespace && quote == nil {
                if started { words.append(word); word = ""; started = false }
            } else { word.append(character); started = true }
        }
        guard quote == nil else { throw invalidCURL() }
        if started { words.append(word) }
        return words
    }

    private static func invalidCURL() -> TransferError {
        TransferError(message: "Paste a complete cURL provider export or a GET check request. Shell commands, file references, and JSON configurations are not supported.")
    }

    static func plan(_ configurations: [Configuration], existing: [ProviderConnection],
                     policy: ModelsImportPolicy) throws -> [ImportItem] {
        var connections = existing
        var result: [ImportItem] = []
        for configuration in configurations {
            var connection = configuration.connection
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
