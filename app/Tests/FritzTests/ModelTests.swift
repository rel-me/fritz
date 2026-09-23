import XCTest
import Fritz
import FritzUpdates
@testable import FritzApp

final class ModelTests: XCTestCase {
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

    @MainActor func testCorruptTranscriptSurfacesErrorWithoutOverwriting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("chat.json")
        try Data("corrupt".utf8).write(to: url)
        let store = ChatStore(agent: AgentClient(), transcriptURL: url)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "corrupt")
    }

    @MainActor func testRestoresTranscriptAndPreservesInterruptedState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("chat.json")
        let messages = [ChatMessage(role: "user", content: "Hello"), ChatMessage(role: "assistant", content: "Partial", isComplete: false)]
        try JSONEncoder().encode(messages).write(to: url)
        let store = ChatStore(agent: AgentClient(), transcriptURL: url)
        XCTAssertEqual(store.messages, messages)
        XCTAssertFalse(store.canSend)
        store.clear()
        XCTAssertEqual(try JSONDecoder().decode([ChatMessage].self, from: Data(contentsOf: url)), [])
    }
}
