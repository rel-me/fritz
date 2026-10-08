import XCTest
import Fritz
import FritzUpdates
@testable import FritzApp

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

    func testLegacyStateIsIgnored() throws {
        let root = try directory()
        for name in ["chat.json", "workspace.json", "providers.json"] {
            try Data("old state".utf8).write(to: root.appendingPathComponent(name))
        }
        let workspace = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        XCTAssertTrue(workspace.projects.isEmpty)
        XCTAssertTrue(workspace.canSave)
        try workspace.createProject(name: "Fresh", directory: root)
        XCTAssertEqual(WorkspaceStore(agent: AgentClient(), dataDirectory: root).projects.first?.name, "Fresh")
    }

    func testUnreadableWorkspaceCannotBeOverwritten() throws {
        let root = try directory()
        let file = root.appendingPathComponent("workspace.sqlite")
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

    func testDefaultProjectFolderNamesStayWithinDocumentsFritz() {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Fritz")
        for (name, leaf) in [
            ("  My Project  ", "My-Project"),
            ("Notes/2026: plans\\draft?*<>|\"", "Notes-2026-plans-draft-"),
            ("Two\twords\nnext\u{0000}part", "Two-words-next-part"),
            ("../Outside", "-Outside"),
            (".", "Project"),
            ("..", "Project"),
            ("Café 日記", "Café-日記"),
        ] {
            XCTAssertEqual(WorkspaceStore.defaultProjectDirectory(name: name).path,
                           root.appendingPathComponent(leaf).path, name)
        }
    }

    func testProjectWithoutChosenFolderCreatesAndPersistsDefaultDirectory() throws {
        let data = try directory()
        let workspace = WorkspaceStore(agent: AgentClient(), dataDirectory: data)
        let prefix = "Fritz-test-\(UUID())"
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Fritz/\(prefix)-My-Project")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let projectID = try workspace.createProject(name: "\(prefix) My/Project")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let restored = WorkspaceStore(agent: AgentClient(), dataDirectory: data)
        XCTAssertEqual(restored.selectedProject?.id, projectID)
        XCTAssertEqual(restored.selectedProject?.name, "\(prefix) My/Project")
        XCTAssertEqual(restored.selectedChat?.projectPath, folder.resolvingSymlinksInPath().path)
        // Distinct display names can normalize to the same folder; do not add it twice.
        XCTAssertThrowsError(try workspace.createProject(name: "\(prefix) My:Project"))
        XCTAssertEqual(workspace.projects.count, 1)
    }

    func testProjectThreadsKeepTheirOwnWorkspace() throws {
        let root = try directory()
        let firstFolder = root.appendingPathComponent("first")
        let secondFolder = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        let workspace = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        try workspace.createProject(name: "One", directory: firstFolder)
        let firstID = try XCTUnwrap(workspace.selectedThreadID)
        let first = try XCTUnwrap(workspace.selectedChat)
        XCTAssertEqual(first.projectPath, firstFolder.resolvingSymlinksInPath().path)
        try workspace.createProject(name: "Two", directory: secondFolder)
        XCTAssertEqual(workspace.selectedChat?.projectPath, secondFolder.resolvingSymlinksInPath().path)
        workspace.shutdown()
        let restored = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        restored.select(firstID)
        XCTAssertEqual(restored.selectedChat?.projectPath, firstFolder.resolvingSymlinksInPath().path)
    }

    func testInterruptedToolsSurviveRestartAndRemainInContext() throws {
        let root = try directory()
        let database = AppDatabase(directory: root)
        let thread = ProjectThread()
        try database.saveWorkspace(WorkspaceDocument(projects: [FritzProject(name: "Test", threads: [thread])], selectedThreadID: thread.id))
        let preferences = ChatPreferences(draft: "", effort: .medium, speed: .standard)
        let assistantID = UUID()
        let messages = [ChatMessage(id: assistantID, role: "assistant", content: "", isComplete: false)]
        try database.save(messages: messages, preferences: preferences, for: thread.id)
        let store = ChatStore(agent: AgentClient(), database: database, threadID: thread.id)
        let start = Data(#"{"id":"request","type":"tool_start","toolCallId":"call","name":"edit_file","summary":"hello.txt","details":"arguments"}"#.utf8)
        store.recordToolEvent(try JSONDecoder().decode(AgentEvent.self, from: start), assistantID: assistantID)
        // Serialize an interrupted run as it would be saved on Stop or at each tool event.
        try database.save(messages: store.messages, preferences: preferences, for: thread.id)
        let restored = ChatStore(agent: AgentClient(), database: database, threadID: thread.id)
        XCTAssertEqual(restored.messages.first?.tools?.count, 1)
        XCTAssertTrue(restored.contextMessages[0]["content"]?.contains("may have taken effect") == true)
        let end = Data(#"{"id":"request","type":"tool_end","toolCallId":"call","name":"edit_file","success":true,"details":"edited hello.txt"}"#.utf8)
        restored.recordToolEvent(try JSONDecoder().decode(AgentEvent.self, from: end), assistantID: assistantID)
        XCTAssertEqual(restored.messages.first?.tools?.first?.success, true)
        XCTAssertTrue(restored.contextMessages[0]["content"]?.contains("edited hello.txt") == true)
    }

    func testConversationBeforeWorkTimingStillLoadsAndKeepsToolDetails() throws {
        let legacy = Data(#"{"id":"00000000-0000-0000-0000-000000000001","role":"assistant","content":"Done","isComplete":true,"tools":[{"id":"call","name":"read_file","summary":"notes.txt","arguments":"{}","result":"Notes","success":true}]}"#.utf8)
        var message = try JSONDecoder().decode(ChatMessage.self, from: legacy)
        XCTAssertNil(message.elapsedTime)
        XCTAssertNil(message.usageSummary)
        let database = AppDatabase(directory: try directory())
        let thread = ProjectThread()
        try database.saveWorkspace(WorkspaceDocument(projects: [FritzProject(name: "Test", threads: [thread])], selectedThreadID: thread.id))
        message.elapsedTime = 12.5
        message.usageSummary = ChatResponseUsageSummary(usage: ChatUsage(calls: [ChatUsageCall(reported: true, inputTokens: 100, outputTokens: 20, totalTokens: 120, cachedInputTokens: 50)]), modelName: "Fixture", costUSD: 0.0123, costSource: "provider")
        try database.save(messages: [message], preferences: ChatPreferences(draft: "", effort: .medium, speed: .standard), for: thread.id)
        let restored = ChatStore(agent: AgentClient(), database: database, threadID: thread.id)
        XCTAssertEqual(restored.messages.first?.elapsedTime, 12.5)
        XCTAssertEqual(restored.messages.first?.usageSummary, message.usageSummary)
        XCTAssertEqual(restored.messages.first?.tools?.first?.result, "Notes")
        XCTAssertTrue(restored.contextMessages[0]["content"]?.contains("Notes") == true)
    }

    func testSettingsAndRecentsAreIsolatedAndSurviveRestart() throws {
        let root = try directory()
        let database = AppDatabase(directory: root)
        let settings = AppSettings(database: database)
        settings.appearance = "dark"
        settings.updateChannel = "beta"
        settings.selectedTab = "providers"
        let providers = ProviderStore(agent: AgentClient(), database: database)
        let localModels = LocalModelRuntimeStore(agent: AgentClient(), database: database)
        XCTAssertEqual(localModels.policy(for: "model-a"), .firstUse)
        try localModels.setPolicy(.appStart, for: "model-a")
        providers.record(ChatModelOption(id: "chosen", displayName: "Chosen", provider: .openAI, modelID: "gpt-5"))
        let restoredDatabase = AppDatabase(directory: root)
        let restored = AppSettings(database: restoredDatabase)
        XCTAssertEqual(restored.appearance, "dark")
        XCTAssertEqual(restored.updateChannel, "beta")
        XCTAssertEqual(restored.selectedTab, "providers")
        XCTAssertEqual(ProviderStore(agent: AgentClient(), database: restoredDatabase).recentIDs, ["chosen"])
        XCTAssertEqual(LocalModelRuntimeStore(agent: AgentClient(), database: restoredDatabase).policy(for: "model-a"), .appStart)
        let separate = AppSettings(database: AppDatabase(directory: try directory()))
        XCTAssertEqual(separate.appearance, "system")
        XCTAssertEqual(separate.updateChannel, "release")
        XCTAssertEqual(LocalModelRuntimeStore(agent: AgentClient(), database: AppDatabase(directory: try directory())).policy(for: "model-a"), .firstUse)
    }

    func testDevUpdateChannelMigratesToStaging() throws {
        let root = try directory()
        let database = AppDatabase(directory: root)
        try database.set("dev", for: "updateChannel")

        let settings = AppSettings(database: database)
        XCTAssertNil(settings.error)
        XCTAssertEqual(settings.updateChannel, "staging")
        XCTAssertEqual(try database.setting("updateChannel"), "staging")
        XCTAssertEqual(AppSettings(database: AppDatabase(directory: root)).updateChannel, "staging")
    }

    func testRemovingThreadsCascadesTheirHistoryAndPreferences() throws {
        let database = AppDatabase(directory: try directory())
        let thread = ProjectThread()
        let document = WorkspaceDocument(projects: [FritzProject(name: "Test", threads: [thread])], selectedThreadID: thread.id)
        try database.saveWorkspace(document)
        let preferences = ChatPreferences(draft: "Draft", effort: .medium, speed: .standard)
        try database.save(messages: [ChatMessage(role: "user", content: "Hello")], preferences: preferences, for: thread.id)
        try database.saveWorkspace(WorkspaceDocument())
        XCTAssertTrue(try database.messages(for: thread.id).isEmpty)
        XCTAssertNil(try database.preferences(for: thread.id))
        XCTAssertNil(try database.loadWorkspace().selectedThreadID)
        XCTAssertThrowsError(try database.save(messages: [ChatMessage(role: "user", content: "Orphan")], preferences: preferences, for: thread.id))
        XCTAssertTrue(try database.messages(for: thread.id).isEmpty)
    }

    func testProviderCategoriesDistinguishCustomEndpointsAndHostedPresets() {
        XCTAssertTrue(AIProviderCategory.system1.contains(.adapter(.jev)))
        XCTAssertTrue(AIProviderCategory.system1.contains(.adapter(.ollaya)))
        XCTAssertFalse(AIProviderCategory.system1.contains(.adapter(.openAI)))
        XCTAssertTrue(AIProviderCategory.local.contains(.adapter(.ollama)))
        XCTAssertFalse(AIProviderCategory.remote.contains(.adapter(.ollama)))
        XCTAssertTrue(AIProviderCategory.hosted.contains(.fireworks))
        XCTAssertFalse(AIProviderCategory.custom.contains(.fireworks))
        XCTAssertTrue(AIProviderCategory.custom.contains(.adapter(.openAICompatible)))
        XCTAssertTrue(AIProviderCategory.frontier.contains(.adapter(.anthropic)))
    }
}
