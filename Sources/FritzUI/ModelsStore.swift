import Fritz
import Foundation
import Observation
import Security

@MainActor @Observable public final class ModelsStore: ModelsProviderStore {
    public private(set) var registry = ProviderRegistry()
    public private(set) var models: [ChatModelOption] = []
    public private(set) var catalog: [UUID: [DiscoveredAIModel]] = [:]
    public private(set) var discoveryErrors: [UUID: String] = [:]
    public private(set) var isLoading = false
    public private(set) var hasLoadedModels = false
    public var error: String?
    public var recentIDs: [String] = []
    private let database: any ModelsPreferences
    public let agent: AgentClient
    private let keychainService: String
    @ObservationIgnored private var refreshID = UUID()

    public init(agent: AgentClient, preferences: any ModelsPreferences, keychainService: String) {
        self.agent = agent
        self.keychainService = keychainService
        self.database = preferences
        do { recentIDs = try preferences.setting("recentModelIDs") ?? [] }
        catch { self.error = error.localizedDescription }
    }
    public var connections: [ProviderConnection] { registry.connections }
    public var providerOrder: [AIProviderKind] { connections.filter { $0.category == .llm }.map(\.provider) }
    public var recentModels: [ChatModelOption] { recentIDs.compactMap { id in models.first { $0.id == id } } }
    public var defaultModel: ChatModelOption? {
        if let recent = recentModels.first { return recent }
        if let connection = connections.first(where: { $0.id == registry.defaultConnectionId }),
           let model = models.first(where: { $0.connectionID == connection.id && $0.modelID == connection.modelID }) { return model }
        return models.first(where: { $0.connectionID == registry.defaultConnectionId && $0.capabilities.isRecommendedInChatPicker })
            ?? models.first(where: { $0.capabilities.isRecommendedInChatPicker })
    }

    public func record(_ model: ChatModelOption) {
        recentIDs.removeAll { $0 == model.id }
        recentIDs.insert(model.id, at: 0)
        recentIDs = Array(recentIDs.prefix(8))
        do { try database.set(recentIDs, for: "recentModelIDs") }
        catch { self.error = error.localizedDescription }
    }

    public func refresh() async {
        let revision = UUID()
        refreshID = revision
        isLoading = true; error = nil
        defer { if refreshID == revision { isLoading = false } }
        do {
            let registry: ProviderRegistry = try await agent.request("providers.list")
            guard refreshID == revision else { return }
            self.registry = registry
            var nextModels: [ChatModelOption] = []
            var nextCatalog: [UUID: [DiscoveredAIModel]] = [:]
            var nextErrors: [UUID: String] = [:]
            for connection in registry.connections {
                do {
                    let response: ModelCatalog = try await agent.request("models.list", params: ["connectionId": connection.id.uuidString])
                    guard refreshID == revision else { return }
                    nextCatalog[connection.id] = response.models
                    if connection.category == .llm {
                        nextModels += response.models.map { ChatModelOption(connection: connection, model: $0) }
                    }
                    if connection.provider.isNative, response.models.isEmpty {
                        nextErrors[connection.id] = "No local models installed."
                    }
                } catch {
                    guard refreshID == revision else { return }
                    nextErrors[connection.id] = error.localizedDescription
                }
                // A manually configured model supports endpoints that have no catalog API.
                if connection.category == .llm, !connection.provider.isNative, !connection.modelID.isEmpty && !nextModels.contains(where: { $0.connectionID == connection.id && $0.modelID == connection.modelID }) {
                    nextModels.append(ChatModelOption(connection: connection))
                }
            }
            guard refreshID == revision else { return }
            models = nextModels; catalog = nextCatalog; discoveryErrors = nextErrors
            hasLoadedModels = true
        } catch { if refreshID == revision { self.error = error.localizedDescription } }
    }

    public func save(_ connection: ProviderConnection, key: String, makeDefault: Bool) async throws {
        var params: [String: Any] = ["connection": try connection.jsonObject(), "makeDefault": makeDefault]
        if !key.isEmpty { params["apiKey"] = key }
        registry = try await agent.request("providers.save", params: params)
        await refresh()
    }

    /// Rust copies referenced credentials and commits the migration completion record
    /// with the provider records. Repeating a completed migration returns its original mapping.
    public func migrate(_ migration: ProviderMigration) async throws -> ProviderMigrationResult {
        let result: ProviderMigrationResult = try await agent.request("providers.migrate", params: try migration.jsonObject())
        await refresh()
        return result
    }

    public func migrationResult(id: String) async throws -> ProviderMigrationResult? {
        struct Status: Decodable { let migration: ProviderMigrationResult? }
        let status: Status = try await agent.request("providers.migrationStatus", params: ["migrationId": id])
        return status.migration
    }

    public func importProviders(_ text: String, policy: ModelsImportPolicy) async throws {
        let configurations = try ProviderConfigurationTransfer.decode(text)
        let current: ProviderRegistry = try await agent.request("providers.list")
        let items = try ProviderConfigurationTransfer.plan(configurations, existing: current.connections, policy: policy)
        do {
            registry = try await agent.request("providers.import", params: ["providers": try items.map { try $0.jsonObject() }])
        } catch {
            // A Keychain/storage failure can occur after earlier entries were saved.
            await refresh()
            throw error
        }
        await refresh()
    }

    public func exportProviders(_ connections: [ProviderConnection], includeKeys: Bool) throws -> String {
        let configurations = try connections.map { connection in
            ProviderConfigurationTransfer.Configuration(connection, apiKey: includeKeys ? try exportKey(for: connection) : nil)
        }
        return try ProviderConfigurationTransfer.exportCURL(configurations)
    }

    /// Only an explicit key-inclusive export reads credentials in the UI process.
    /// The agent protocol continues to return metadata only.
    private func exportKey(for connection: ProviderConnection) throws -> String? {
        guard !connection.provider.isNative else { return nil }
        let service = keychainService
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connection.id.uuidString.lowercased(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw ProviderConfigurationTransfer.TransferError(message: "Could not read a provider key from Keychain (\(status)).")
        }
        return key
    }
    public func remove(_ connection: ProviderConnection) async {
        do { registry = try await agent.request("providers.remove", params: ["id": connection.id.uuidString]); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    public func makeDefault(_ connection: ProviderConnection) async {
        do { registry = try await agent.request("providers.default", params: ["id": connection.id.uuidString]) }
        catch { self.error = error.localizedDescription }
    }
}

extension ModelsStore {
    public var defaultConnectionID: UUID? { registry.defaultConnectionId }
    public var nativeModelCatalog: [NativeModelDescriptor] { NativeModelDescriptor.catalog + NativeModelDescriptor.decisionCatalog }
    public func discoverModels(_ connection: ProviderConnection, key: String) async throws -> [DiscoveredAIModel] {
        var params: [String: Any] = ["connection": try connection.jsonObject()]
        if !key.isEmpty { params["apiKey"] = key }
        let response: ModelCatalog = try await agent.request("models.list", params: params)
        return response.models
    }
    public func modelEvents(category: AIModelCategory, modelID: String, install: Bool, directory: URL?,
                     requestID: String) -> AsyncThrowingStream<Data, Error> {
        let prefix = category == .decision ? "decisionModels" : "localModels"
        var params: [String: Any] = ["modelId": modelID]
        if let directory { params["directory"] = directory.path }
        return agent.stream(method: "\(prefix).\(install ? "install" : "list")",
                            params: params, id: requestID)
    }
    public func cancelModelRequest(_ requestID: String) { agent.cancel(requestID) }
}
