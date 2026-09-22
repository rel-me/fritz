import XCTest
@testable import Fritz

@MainActor final class WorkspaceTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fritz-workspace-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testProjectsThreadsAndSelectionSurviveRestart() throws {
        let root = try directory()
        let workspace = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        let projectID = try workspace.createProject(name: "Example", directory: root)
        let first = try XCTUnwrap(workspace.selectedThreadID)
        workspace.createThread(in: projectID)
        let second = try XCTUnwrap(workspace.selectedThreadID)
        XCTAssertNotEqual(first, second)
        workspace.renameThread(second, to: "Investigate a failure")
        workspace.select(first)
        let restored = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        XCTAssertEqual(restored.projects.first?.threads.count, 2)
        XCTAssertEqual(restored.selectedThreadID, first)
        XCTAssertEqual(restored.projects.first?.threads.last?.title, "Investigate a failure")
    }

    func testSwitchingThreadsPreservesIndependentDraftsAndModels() throws {
        let root = try directory()
        let workspace = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        let project = try workspace.createProject(name: "Example", directory: root)
        let firstID = try XCTUnwrap(workspace.selectedThreadID)
        let first = try XCTUnwrap(workspace.selectedChat)
        first.draft = "First draft"
        first.select(ChatModelOption(id: "model-a", displayName: "A", provider: .openAI, modelID: "gpt-5"))
        workspace.createThread(in: project)
        let second = try XCTUnwrap(workspace.selectedChat)
        XCTAssertTrue(second.draft.isEmpty)
        second.draft = "Second draft"
        workspace.shutdown()
        let restored = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        XCTAssertEqual(restored.selectedChat?.draft, "Second draft")
        restored.select(firstID)
        XCTAssertEqual(restored.selectedChat?.draft, "First draft")
        XCTAssertEqual(restored.selectedChat?.selectedModel?.id, "model-a")
    }

    func testPreviousConversationIsImportedExactlyOnceWithoutRemovingOriginal() throws {
        let root = try directory()
        let messages = [ChatMessage(role: "user", content: "Keep this message")]
        let original = try JSONEncoder().encode(messages)
        let legacy = root.appendingPathComponent("chat.json")
        try original.write(to: legacy)
        let workspace = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        XCTAssertEqual(workspace.projects.first?.name, "Chats")
        XCTAssertEqual(workspace.selectedChat?.messages, messages)
        XCTAssertEqual(try Data(contentsOf: legacy), original)
        let restored = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        XCTAssertEqual(restored.projects, workspace.projects)
    }

    func testUnreadableWorkspaceCannotBeOverwritten() throws {
        let root = try directory()
        let file = root.appendingPathComponent("workspace.json")
        try Data("invalid".utf8).write(to: file)
        let workspace = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        XCTAssertFalse(workspace.canSave)
        XCTAssertNotNil(workspace.error)
        XCTAssertThrowsError(try workspace.createProject(name: "New", directory: root))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "invalid")
    }

    func testDuplicateProjectFolderIsRejected() throws {
        let root = try directory()
        let workspace = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        try workspace.createProject(name: "One", directory: root)
        XCTAssertThrowsError(try workspace.createProject(name: "Two", directory: root.appendingPathComponent(".")))
        XCTAssertEqual(workspace.projects.count, 1)
    }

    func testProviderCategoriesDistinguishCustomEndpointsAndHostedPresets() {
        XCTAssertTrue(AIProviderCategory.local.contains(.adapter(.ollama)))
        XCTAssertFalse(AIProviderCategory.remote.contains(.adapter(.ollama)))
        XCTAssertTrue(AIProviderCategory.hosted.contains(.fireworks))
        XCTAssertFalse(AIProviderCategory.custom.contains(.fireworks))
        XCTAssertTrue(AIProviderCategory.custom.contains(.adapter(.openAICompatible)))
        XCTAssertTrue(AIProviderCategory.frontier.contains(.adapter(.anthropic)))
    }
}
