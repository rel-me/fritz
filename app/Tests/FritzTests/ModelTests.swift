import XCTest
import Fritz
import FritzUpdates
@testable import FritzApp

final class ModelTests: XCTestCase {
    @MainActor func testChangingModelsKeepsOnlySupportedReasoningAndSpeedSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(agent: AgentClient(), database: AppDatabase(directory: root), threadID: UUID())
        store.select(ChatModelOption(connection: ProviderConnection(name: "OpenAI", provider: .openAI, modelID: "gpt-6-luna")))
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
