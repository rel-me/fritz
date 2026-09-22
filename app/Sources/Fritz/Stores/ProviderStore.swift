import Foundation
import Observation

@MainActor @Observable final class ProviderStore {
    private(set) var registry = ProviderRegistry()
    private(set) var models: [ChatModelOption] = []
    private(set) var catalog: [UUID: [DiscoveredAIModel]] = [:]
    private(set) var discoveryErrors: [UUID: String] = [:]
    private(set) var isLoading = false
    private(set) var hasLoadedModels = false
    var error: String?
    var recentIDs: [String] = UserDefaults.standard.stringArray(forKey: "recentModelIDs") ?? []
    let agent: AgentClient
    @ObservationIgnored private var refreshID = UUID()

    init(agent: AgentClient) { self.agent = agent }
    var connections: [ProviderConnection] { registry.connections }
    var providerOrder: [AIProviderKind] { connections.map(\.provider) }
    var recentModels: [ChatModelOption] { recentIDs.compactMap { id in models.first { $0.id == id } } }
    var defaultModel: ChatModelOption? {
        if let recent = recentModels.first { return recent }
        if let connection = connections.first(where: { $0.id == registry.defaultConnectionId }),
           let model = models.first(where: { $0.connectionID == connection.id && $0.modelID == connection.modelID }) { return model }
        return models.first(where: { $0.connectionID == registry.defaultConnectionId && $0.capabilities.isRecommendedInChatPicker })
            ?? models.first(where: { $0.capabilities.isRecommendedInChatPicker })
    }

    func record(_ model: ChatModelOption) {
        recentIDs.removeAll { $0 == model.id }
        recentIDs.insert(model.id, at: 0)
        recentIDs = Array(recentIDs.prefix(8))
        UserDefaults.standard.set(recentIDs, forKey: "recentModelIDs")
    }

    func refresh() async {
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
                    nextModels += response.models.map { ChatModelOption(connection: connection, model: $0) }
                    if connection.provider == .fritz, response.models.isEmpty {
                        nextErrors[connection.id] = "No local models are installed. Edit this provider to download a model."
                    }
                } catch {
                    guard refreshID == revision else { return }
                    nextErrors[connection.id] = error.localizedDescription
                }
                // A manually configured model supports endpoints that have no catalog API.
                if connection.provider != .fritz, !connection.modelID.isEmpty && !nextModels.contains(where: { $0.connectionID == connection.id && $0.modelID == connection.modelID }) {
                    nextModels.append(ChatModelOption(connection: connection))
                }
            }
            guard refreshID == revision else { return }
            models = nextModels; catalog = nextCatalog; discoveryErrors = nextErrors
            hasLoadedModels = true
        } catch { if refreshID == revision { self.error = error.localizedDescription } }
    }

    func save(_ connection: ProviderConnection, key: String, makeDefault: Bool) async throws {
        var params: [String: Any] = ["connection": try connection.jsonObject(), "makeDefault": makeDefault]
        if !key.isEmpty { params["apiKey"] = key }
        registry = try await agent.request("providers.save", params: params)
        await refresh()
    }
    func remove(_ connection: ProviderConnection) async {
        do { registry = try await agent.request("providers.remove", params: ["id": connection.id.uuidString]); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func makeDefault(_ connection: ProviderConnection) async {
        do { registry = try await agent.request("providers.default", params: ["id": connection.id.uuidString]) }
        catch { self.error = error.localizedDescription }
    }
}
