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
    public let modelCatalog: RemoteModelCatalog
    private let keychainService: String
    @ObservationIgnored private var refreshID = UUID()

    public init(agent: AgentClient, preferences: any ModelsPreferences, keychainService: String, modelCatalog: RemoteModelCatalog? = nil) {
        self.agent = agent
        self.keychainService = keychainService
        self.database = preferences
        self.modelCatalog = modelCatalog ?? RemoteModelCatalog()
        do { recentIDs = try preferences.setting("recentModelIDs") ?? [] }
        catch { self.error = error.localizedDescription }
    }
    public var connections: [ProviderConnection] { registry.connections }
    public var providerOrder: [AIProviderKind] { connections.filter { $0.category == .llm }.map(\.provider) }
    public var recentModels: [ChatModelOption] { recentIDs.compactMap { id in models.first { $0.id == id } } }
    public var availableModels: [ChatModelOption] {
        let discovered = models + connections.filter { $0.category == .decision }.flatMap { connection in
            (catalog[connection.id] ?? [DiscoveredAIModel(id: connection.modelID, displayName: connection.modelID)])
                .map { ChatModelOption(connection: connection, model: $0) }
        }
        var configured: [ChatModelOption] = []
        var nativeRows: [String: Int] = [:]
        for model in discovered {
            if model.provider.isNative, let index = nativeRows[model.usageKey] {
                if connections.contains(where: { $0.id == model.connectionID && $0.modelID == model.modelID }) {
                    configured[index] = model
                }
            } else {
                if model.provider.isNative { nativeRows[model.usageKey] = configured.count }
                configured.append(model)
            }
        }
        let local = nativeModelCatalog.map {
            ChatModelOption(id: "catalog:\($0.id)", displayName: $0.name,
                            provider: $0.category == .llm ? .fritz : .ollaya, modelID: $0.id)
        }
        let decisions = AIProviderPreset.allCases.filter { $0.category == .decision && AIProviderCategory.remote.contains($0) }.map {
            ChatModelOption(id: "catalog:\($0.id)", displayName: $0.name, provider: $0.provider,
                            modelID: $0.provider.decisionModelID, baseURL: $0.baseURL)
        }
        let configuredKeys = Set(configured.map { "\($0.displayProvider.id):\($0.modelID)" })
        return configured + (local + modelCatalog.chatModels + decisions).filter {
            !configuredKeys.contains("\($0.displayProvider.id):\($0.modelID)")
        }
    }
    public var pickerModels: [ChatModelOption] {
        let knownChat = Set(modelCatalog.chatModels.map(\.usageKey))
        return availableModels.filter {
            $0.category == .llm && ($0.provider == .fritz || knownChat.contains($0.usageKey)
                || $0.capabilities.isRecommendedInChatPicker || $0.status == .deprecated)
        }
    }

    public func setupConnection(for model: ChatModelOption) -> ProviderConnection? {
        if model.provider.isNative { return connections.first { $0.provider == model.provider && $0.modelID == model.modelID } }
        if let id = model.connectionID { return connections.first { $0.id == id } }
        let endpoint = model.displayProvider.baseURL.isEmpty ? model.provider.endpoint : model.displayProvider.baseURL
        return connections.first {
            AIProviderPreset.matching(provider: $0.provider, baseURL: $0.baseURL) == model.displayProvider
                && ($0.baseURL?.isEmpty == false ? $0.baseURL! : $0.provider.endpoint)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                == endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
    }
    /// A catalog choice gets a real connection only after local inventory confirms installation.
    public func prepareLocalModel(_ model: ChatModelOption) async throws -> ChatModelOption? {
        guard model.provider == .fritz,
              nativeModelCatalog.contains(where: { $0.id == model.modelID && $0.category == .llm }) else {
            throw AgentFailure(message: "This model is not in Fritz's local chat catalog.")
        }
        struct Inventory: Decodable {
            struct Item: Decodable { let id: String; let installed: Bool }
            let models: [Item]
        }
        let inventory: Inventory = try await agent.request("localModels.list")
        try Task.checkCancellation()
        guard inventory.models.contains(where: { $0.id == model.modelID && $0.installed }) else { return nil }
        let current: ProviderRegistry = try await agent.request("providers.list")
        try Task.checkCancellation()
        registry = current
        var name = model.displayName
        var suffix = 2
        while connections.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(model.displayName) \(suffix)"; suffix += 1
        }
        let connection = setupConnection(for: model)
            ?? ProviderConnection(name: name, provider: .fritz, modelID: model.modelID)
        if !connections.contains(where: { $0.id == connection.id }) {
            try await save(connection, key: "", makeDefault: defaultConnectionID == nil)
        }
        try Task.checkCancellation()
        return ChatModelOption(connection: connection, model: .init(id: model.modelID, displayName: model.displayName))
    }

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
        async let catalogRefresh: Void = modelCatalog.refresh()
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
                    let available = presentedModels(response.models, provider: connection.provider)
                    nextCatalog[connection.id] = available
                    if connection.category == .llm {
                        nextModels += DiscoveredAIModel.preferredOrder(available, provider: connection.provider)
                            .map { ChatModelOption(connection: connection, model: $0) }
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
                    let model = ChatModelOption(connection: connection)
                    if model.status != .retired { nextModels.append(model) }
                }
            }
            guard refreshID == revision else { return }
            models = nextModels; catalog = nextCatalog; discoveryErrors = nextErrors
            hasLoadedModels = true
            await catalogRefresh
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
        return presentedModels(response.models, provider: connection.provider)
    }

    private func presentedModels(_ models: [DiscoveredAIModel], provider: AIProviderKind) -> [DiscoveredAIModel] {
        guard provider == .openAI else { return models }
        return models.filter { ChatModelOption(id: $0.id, displayName: $0.displayName,
            provider: provider, modelID: $0.id).status != .retired }.map { DiscoveredAIModel(id: $0.id,
            displayName: OpenAIModelCatalog.displayName(modelID: $0.id, fallback: $0.displayName)) }
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
