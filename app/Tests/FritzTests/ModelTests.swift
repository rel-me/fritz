import XCTest
import Fritz
import FritzUpdates
@testable import FritzApp

final class ModelTests: XCTestCase {
    @MainActor func testUnconfiguredCatalogChoicesRemainSeparateFromReadyModels() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let providers = ProviderStore(agent: AgentClient(), database: AppDatabase(directory: directory))
        let local = try XCTUnwrap(providers.pickerModels.first { $0.provider == .fritz })
        let remote = try XCTUnwrap(providers.pickerModels.first { $0.provider == .anthropic })
        for model in [local, remote] {
            XCTAssertNil(model.connectionID)
            XCTAssertEqual(model.source, .builtIn)
            XCTAssertNil(providers.setupConnection(for: model))
        }
        XCTAssertTrue(providers.connections.isEmpty)
        XCTAssertTrue(providers.models.isEmpty)
        XCTAssertNil(providers.defaultModel)
        XCTAssertTrue(providers.availableModels.contains { $0.category == .decision })
        XCTAssertTrue(providers.pickerModels.allSatisfy { $0.category == .llm })
    }

    @MainActor func testNativeCatalogUsesOneRowPerInstalledModelAndItsOwnConnection() async throws {
        let script = #"""
        import json, sys
        a = {'id':'00000000-0000-0000-0000-000000000001','name':'A','provider':'fritz','modelId':'qwen3-0.6b-q4_k_m'}
        b = {'id':'00000000-0000-0000-0000-000000000002','name':'B','provider':'fritz','modelId':'qwen3-1.7b-q4_k_m'}
        for line in sys.stdin:
            r = json.loads(line)
            result = {'version':1,'connections':[a,b]} if r['method']=='providers.list' else {'models':[{'id':a['modelId'],'displayName':'A'},{'id':b['modelId'],'displayName':'B'}]}
            print(json.dumps({'id':r['id'],'type':'result','result':result}),flush=True)
        """#
        let agent = AgentClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                                arguments: ["-u", "-c", script], environment: ["PATH":"/usr/bin:/bin"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { agent.stop(); try? FileManager.default.removeItem(at: directory) }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [OfflineCatalogProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let store = ProviderStore(agent: agent, database: AppDatabase(directory: directory),
                                  modelCatalog: RemoteModelCatalog(session: session))
        agent.start()
        await store.refresh()
        let ready = store.pickerModels.filter { $0.provider == .fritz && $0.connectionID != nil }
        XCTAssertEqual(ready.count, 2)
        XCTAssertEqual(Set(ready.map(\.modelID)), ["qwen3-0.6b-q4_k_m", "qwen3-1.7b-q4_k_m"])
        for model in ready {
            let connection = try XCTUnwrap(store.setupConnection(for: model))
            XCTAssertEqual(connection.id, model.connectionID)
            XCTAssertEqual(connection.modelID, model.modelID)
        }
    }

    @MainActor func testLocalSelectionRegistersOnlyAfterInstallationAndReturnsTheChosenConnection() async throws {
        let script = #"""
        import json,sys
        connections=[]
        inventories=0
        for line in sys.stdin:
            r=json.loads(line)
            if r['method']=='localModels.list':
                inventories+=1
                result={'models':[{'id':'qwen3-0.6b-q4_k_m','installed':inventories>1}]}
            elif r['method']=='providers.save':
                connections=[r['params']['connection']]
                result={'version':1,'connections':connections}
            elif r['method']=='providers.list': result={'version':1,'connections':connections}
            else: result={'models':[{'id':'qwen3-0.6b-q4_k_m','displayName':'Local model'}]}
            print(json.dumps({'id':r['id'],'type':'result','result':result}),flush=True)
        """#
        let agent = AgentClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                                arguments: ["-u","-c",script], environment: ["PATH":"/usr/bin:/bin"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineCatalogProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { agent.stop(); session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let store = ProviderStore(agent: agent, database: AppDatabase(directory: directory), modelCatalog: RemoteModelCatalog(session: session))
        let chosen = try XCTUnwrap(store.pickerModels.first { $0.modelID == "qwen3-0.6b-q4_k_m" && $0.provider == .fritz })
        agent.start()
        let missing = try await store.prepareLocalModel(chosen)
        XCTAssertNil(missing)
        XCTAssertTrue(store.connections.isEmpty)
        let prepared = try await store.prepareLocalModel(chosen)
        let ready = try XCTUnwrap(prepared)
        XCTAssertEqual(ready.modelID, chosen.modelID)
        let saved = try XCTUnwrap(store.connections.first)
        XCTAssertEqual(saved.modelID, chosen.modelID)
        XCTAssertEqual(ready.connectionID, saved.id)
        XCTAssertEqual(store.connections.count, 1)
    }

    @MainActor func testChangingModelsKeepsOnlySupportedReasoningAndSpeedSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(agent: AgentClient(), database: AppDatabase(directory: root), threadID: UUID())
        store.select(ChatModelOption(connection: ProviderConnection(name: "OpenAI", provider: .openAI, modelID: "gpt-6-luna")))
        XCTAssertEqual(store.effort, .medium)
        XCTAssertEqual(store.speed, .standard)
        store.effort = .none
        store.speed = .priority
        store.select(ChatModelOption(connection: ProviderConnection(name: "OpenAI", provider: .openAI, modelID: "gpt-6.1-sol")))
        XCTAssertEqual(store.effort, .medium)
        XCTAssertEqual(store.speed, .priority)
        store.effort = .max
        store.select(ChatModelOption(connection: ProviderConnection(name: "OpenAI", provider: .openAI, modelID: "gpt-5")))
        XCTAssertEqual(store.effort, .medium)
        store.select(ChatModelOption(connection: ProviderConnection(name: "Gateway", provider: .openAICompatible, modelID: "gpt-6.1-sol")))
        XCTAssertEqual(store.speed, .standard)
    }

    @MainActor func testDiscoveredChatCatalogRanksCurrentModelsWithoutTruncating() async throws {
        let script = #"""
        import json, sys
        connection = {'id': '00000000-0000-0000-0000-000000000001', 'name': 'Test',
                      'provider': 'openai', 'modelId': 'gpt-4.1'}
        ids = ['gpt-3.5-turbo', 'gpt-4.1', 'gpt-5', 'gpt-5-mini', 'gpt-5-nano',
               'gpt-5.1', 'gpt-5.2', 'gpt-6', 'gpt-6-mini', 'gpt-6-pro', 'o3', 'o4-mini']
        for line in sys.stdin:
            r = json.loads(line)
            result = {'version': 1, 'connections': [connection]} if r['method'] == 'providers.list' else {
                'models': [{'id': id, 'displayName': id} for id in sorted(ids)]}
            print(json.dumps({'id': r['id'], 'type': 'result', 'result': result}), flush=True)
        """#
        let agent = AgentClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                                arguments: ["-u", "-c", script], environment: ["PATH": "/usr/bin:/bin"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { agent.stop(); try? FileManager.default.removeItem(at: directory) }
        let store = ProviderStore(agent: agent, database: AppDatabase(directory: directory))
        agent.start()
        await store.refresh()
        XCTAssertTrue(store.discoveryErrors.isEmpty)
        XCTAssertEqual(store.models.count, 12)
        XCTAssertEqual(Array(store.models.prefix(3).map(\.modelID)), ["gpt-6-pro", "gpt-6", "gpt-6-mini"])
        XCTAssertEqual(store.models.last?.modelID, "gpt-3.5-turbo")
    }

    func testRecentModelsExcludeRemovedConnections() {
        let first = ChatModelOption(id: "one", displayName: "One", provider: .openAI, modelID: "gpt-5")
        let removed = ChatModelOption(id: "old", displayName: "Old", provider: .anthropic, modelID: "claude")
        let sections = ChatModelPickerSection.unfiltered(from: [first], recentModels: [removed, first], providerOrder: [.openAI])
        XCTAssertEqual(sections.first?.id, .recent)
        XCTAssertEqual(sections.first?.models.map(\.id), ["one"])
    }

    func testCompatibleEndpointDoesNotInheritOpenAIControls() {
        let capabilities = ChatModelOption.Capabilities.inferred(provider: .openAICompatible, modelID: "gpt-5")
        XCTAssertFalse(capabilities.supportsReasoningEffort)
        XCTAssertFalse(capabilities.supportsSpeed)
        XCTAssertFalse(ChatModelOption.Capabilities.inferred(provider: .openAI, modelID: "text-embedding-3").isRecommendedInChatPicker)
    }

    func testConnectionWireFormatMatchesRust() throws {
        let connection = ProviderConnection(name: "Local", provider: .openAICompatible, baseURL: "http://localhost:9000/v1", modelID: "local")
        let object = try connection.jsonObject()
        XCTAssertEqual(object["baseUrl"] as? String, connection.baseURL)
        XCTAssertEqual(object["modelId"] as? String, "local")
        XCTAssertEqual(object["provider"] as? String, "openai-compatible")
        let decoded = try JSONDecoder().decode(ProviderConnection.self, from: JSONEncoder().encode(connection))
        XCTAssertEqual(connection, decoded)
    }

    func testDecisionProvidersStayOutOfChat() throws {
        for kind in [AIProviderKind.jev, .ollaya] {
            let decision = ProviderConnection(name: kind.name, provider: kind,
                modelID: kind == .jev ? "jev-latest" : NativeModelDescriptor.decisionCatalog[0].id)
            let decoded = try JSONDecoder().decode(ProviderConnection.self, from: JSONEncoder().encode(decision))
            XCTAssertEqual(decoded, decision)
            let option = ChatModelOption(connection: decoded)
            XCTAssertTrue(ChatModelPickerSection.unfiltered(from: [option], recentModels: [option], providerOrder: [kind]).isEmpty)
        }
    }

    @MainActor func testCorruptTranscriptSurfacesErrorWithoutOverwriting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workspace.sqlite")
        try Data("corrupt".utf8).write(to: url)
        let store = ChatStore(agent: AgentClient(), database: AppDatabase(directory: directory), threadID: UUID())
        XCTAssertNotNil(store.error)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "corrupt")
    }

    @MainActor func testRestoresTranscriptAndPreservesInterruptedState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = AppDatabase(directory: directory)
        let thread = ProjectThread()
        try database.saveWorkspace(WorkspaceDocument(projects: [FritzProject(name: "Test", threads: [thread])], selectedThreadID: thread.id))
        let messages = [ChatMessage(role: "user", content: "Hello"), ChatMessage(role: "assistant", content: "Partial", isComplete: false)]
        try database.save(messages: messages, preferences: ChatPreferences(draft: "", effort: .medium, speed: .standard), for: thread.id)
        let store = ChatStore(agent: AgentClient(), database: database, threadID: thread.id)
        XCTAssertEqual(store.messages, messages)
        XCTAssertFalse(store.canSend)
        store.clear()
        XCTAssertEqual(try database.messages(for: thread.id), [])
    }
}

private final class OfflineCatalogProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
