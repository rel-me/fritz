import Foundation
import Security

struct ChatFailure: LocalizedError {
    let errorDescription: String?
    init(_ reason: String) { errorDescription = reason }
}

enum ProviderKind: String, CaseIterable, Codable, Identifiable {
    case openAI, openRouter, compatible, fritzRemote

    var id: Self { self }
    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .compatible: "OpenAI-compatible"
        case .fritzRemote: "Fritz on a Mac"
        }
    }
    var endpoint: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .compatible, .fritzRemote: ""
        }
    }
}

struct ProviderConnection: Identifiable, Codable, Sendable {
    var id = UUID()
    var kind = ProviderKind.openAI
    var name = ""
    var customEndpoint = ""
    var defaultModel = ""
    var credentialID: UUID?
    var endpoint: String { kind == .compatible || kind == .fritzRemote ? customEndpoint : kind.endpoint }

    var apiEndpoint: String {
        guard kind == .fritzRemote else { return endpoint }
        return endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/fritz/v1"
    }

    func validate(key: Data?) throws {
        let parts = URLComponents(string: endpoint)
        var secure = parts?.scheme?.lowercased() == "https"
        #if targetEnvironment(simulator)
        secure = secure || (parts?.scheme == "http" && parts?.host == "127.0.0.1" && key == nil)
        #endif
        guard secure, let parts, let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw ChatFailure("Enter an HTTPS endpoint without credentials, a query, or a fragment.")
        }
        if kind == .fritzRemote {
            guard parts.scheme?.lowercased() == "https", parts.path.isEmpty || parts.path == "/" else {
                throw ChatFailure("Enter the tunnel’s HTTPS address without a path.")
            }
            guard let key, key.count == 64, key.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            }) else {
                throw ChatFailure("Copy the access key from Fritz on your Mac.")
            }
        } else if kind != .compatible, key == nil {
            throw ChatFailure("Enter an API key for \(kind.title).")
        }
    }
}

struct ChatMessage: Identifiable, Codable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    enum Status: String, Codable { case streaming, stopped, failed }
    var id = UUID()
    let role: Role
    var content: String
    var status: Status? = nil
}

struct Conversation: Identifiable, Codable {
    var id = UUID()
    var title = "New Chat"
    var draft = ""
    var messages: [ChatMessage] = []
    var providerID: UUID?
    var model = ""
}

struct Workspace: Codable {
    var version = 1
    var conversations: [Conversation] = []
    var selectedID: UUID?
    var providers: [ProviderConnection] = []
}

struct WorkspaceFile {
    let url: URL

    init() throws {
        var directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("Fritz", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Persist conversation data on this device without including it in backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        url = directory.appendingPathComponent("workspace.json")
    }

    func read() throws -> Workspace {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return Workspace()
        }
        let workspace = try JSONDecoder().decode(Workspace.self, from: data)
        guard workspace.version == 1 else { throw ChatFailure("Update Fritz to open these chats.") }
        return workspace
    }

    func write(_ state: Workspace) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

enum ProviderKeychain {
    private static func query(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.fritz.ios.providers",
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    static func read(_ id: UUID?) throws -> Data? {
        guard let id else { return nil }
        var attributes = query(id)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        guard status == errSecSuccess, let key = result as? Data else {
            throw ChatFailure("Could not read the provider key from Keychain (\(status)). Enter it again in Providers.")
        }
        return key
    }

    static func insert(_ key: Data, id: UUID) throws {
        var attributes = query(id)
        attributes[kSecValueData as String] = key
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ChatFailure("Could not save the provider key in Keychain (\(status)).")
        }
    }

    static func remove(_ id: UUID?) throws {
        guard let id else { return }
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ChatFailure("Could not remove a retired provider key from Keychain (\(status)).")
        }
    }
}
