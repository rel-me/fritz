import XCTest
import Fritz
import FritzState
import FritzUpdates
@testable import FritzApp

@MainActor final class WorkspaceTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fritz-workspace-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testArchiveRestoreAndDeletionPersistWithoutLosingOtherThreads() async throws {
        let root = try directory()
        let workspace = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        await workspace.restore()
        let project = try await workspace.createProject(name: "Example", directory: root)
        let first = try XCTUnwrap(workspace.selectedThreadID)
        workspace.selectedChat?.draft = "Keep this draft"
        await workspace.setArchived(first, true)
        XCTAssertNil(workspace.selectedThreadID)
        let restored = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        await restored.restore()
        let archived = try await restored.repository.archivedChats()
        XCTAssertEqual(archived.rows.map(\.id), [first])
        await restored.select(first)
        XCTAssertEqual(restored.selectedThread?.isArchived, true)
        XCTAssertTrue(restored.sidebarThreads.isEmpty)
        await restored.setArchived(first, false)
        XCTAssertEqual(restored.selectedThread?.isArchived, false)
        XCTAssertEqual(restored.sidebarThreads.map(\.id), [first])
        let afterRestore = try await restored.repository.archivedChats()
        XCTAssertTrue(afterRestore.rows.isEmpty)
        XCTAssertEqual(restored.selectedChat?.draft, "Keep this draft")
        await restored.createThread(in: project)
        let second = try XCTUnwrap(restored.selectedThreadID)
        await restored.deleteThread(first)
        let deleted = try await restored.repository.preferences(for: first)
        let remaining = try await restored.repository.threads(in: project, includeArchived: true)
        XCTAssertNil(deleted)
        XCTAssertEqual(remaining.rows.map(\.id), [second])
    }

    func testArchivedChatsPageAcrossProjectsByLatestActivity() async throws {
        let root = try directory()
        let otherFolder = try directory()
        let repository = ProjectRepository(directory: root)
        let early = try await repository.createProject(name: "Early project", directory: root, defaultDirectory: root)
        let later = try await repository.createProject(name: "Later project", directory: otherFolder, defaultDirectory: otherFolder)
        try await repository.archive(early.thread.id, archived: true)
        try await repository.archive(later.thread.id, archived: true)
        var laterArchives = [later.thread.id]
        for _ in 0..<ProjectRepository.sidebarPageSize {
            let chat = try await repository.createThread(in: later.project.id)
            try await repository.archive(chat.thread.id, archived: true)
            laterArchives.append(chat.thread.id)
        }
        _ = try await repository.createThread(in: early.project.id)

        // Assign distinct activity times independent of thread creation order,
        // with a tie across the pagination boundary.
        let seed = Process()
        seed.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        seed.arguments = [root.appendingPathComponent("projects.sqlite").path, """
            UPDATE threads SET updated_at = 100;
            UPDATE threads SET updated_at = 200 WHERE id = '\(early.thread.id.uuidString)';
            """]
        try seed.run()
        seed.waitUntilExit()
        XCTAssertEqual(seed.terminationStatus, 0)

        let first = try await repository.archivedChats()
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.rows.first?.id, early.thread.id)
        XCTAssertEqual(first.rows.first?.projectName, "Early project")
        let cursor = try XCTUnwrap(first.rows.last)
        let last = try await repository.archivedChats(before: cursor)
        XCTAssertFalse(last.hasMore)
        XCTAssertEqual((first.rows + last.rows).map(\.id), [early.thread.id] + laterArchives.reversed())
    }

    func testMissingProjectKeepsThreadsAccessibleAndRepairRebindsSelectedChat() async throws {
        let root = try directory()
        let folder = root.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let workspace = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        await workspace.restore()
        let id = try await workspace.createProject(name: "Example", directory: folder)
        let first = try XCTUnwrap(workspace.selectedThreadID)
        workspace.selectedChat?.draft = "Retained"
        await workspace.createThread(in: id)
        let second = try XCTUnwrap(workspace.selectedThreadID)

        try FileManager.default.removeItem(at: folder)
        await workspace.refreshAvailability()
        XCTAssertFalse(workspace.canCreateThread)
        await workspace.createThread(in: id)
        XCTAssertEqual(workspace.sidebarThreads.map(\.id), [first, second])
        await workspace.select(first)
        XCTAssertEqual(workspace.selectedThreadID, first)
        XCTAssertEqual(workspace.selectedChat?.draft, "Retained")
        await workspace.deleteThread(second)
        XCTAssertEqual(workspace.sidebarThreads.map(\.id), [first])

        let missingFolderWorkspace = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        await missingFolderWorkspace.restore()
        XCTAssertEqual(missingFolderWorkspace.selectedThreadID, first)
        XCTAssertEqual(missingFolderWorkspace.selectedChat?.draft, "Retained")
        await workspace.repairProject(id, directory: nil)
        XCTAssertEqual(workspace.selectedChat?.draft, "Retained")
        let replacement = root.appendingPathComponent("Replacement")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        await workspace.repairProject(id, directory: replacement)
        XCTAssertEqual(workspace.selectedChat?.projectPath, replacement.path)
        let restored = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        await restored.restore()
        XCTAssertEqual(restored.selectedProject?.directory, replacement.path)
    }

    func testDeletingProjectRemovesItsThreadsButKeepsItsFilesAndOtherProjects() async throws {
        let root = try directory()
        let folder = root.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("keep.txt")
        try Data("Keep me".utf8).write(to: file)

        let workspace = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        await workspace.restore()
        let other = try await workspace.createProject(name: "Other", directory: root)
        let otherThread = try XCTUnwrap(workspace.selectedThreadID)
        workspace.selectedChat?.draft = "Other draft"

        let project = try await workspace.createProject(name: "Remove", directory: folder)
        let archived = try XCTUnwrap(workspace.selectedThreadID)
        let model = ChatModelOption(connection: ProviderConnection(name: "Mock", provider: .openAICompatible, modelID: "fixture"))
        _ = try await workspace.repository.beginTurn(thread: archived, turn: UUID(), prompt: "Saved message",
            preferences: .init(), model: model, projectPath: workspace.selectedProject?.directory)
        await workspace.setArchived(archived, true)
        await workspace.createThread(in: project)
        let active = try XCTUnwrap(workspace.selectedThreadID)
        workspace.selectedChat?.draft = "Delete this draft"

        await workspace.deleteProject(project)

        XCTAssertEqual(workspace.sidebarProjects.map(\.id), [other])
        XCTAssertNil(workspace.selectedThreadID)
        XCTAssertNil(workspace.expandedProjectID)
        XCTAssertTrue(workspace.sidebarThreads.isEmpty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Keep me")

        let restored = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        await restored.restore()
        XCTAssertNil(restored.selectedThreadID)
        let deletedThreads = try await restored.repository.threads(in: project, includeArchived: true)
        let deletedTranscript = try await restored.repository.transcript(archived)
        let deletedDraft = try await restored.repository.preferences(for: active)
        XCTAssertTrue(deletedThreads.rows.isEmpty)
        XCTAssertTrue(deletedTranscript.isEmpty)
        XCTAssertNil(deletedDraft)
        await restored.select(otherThread)
        XCTAssertEqual(restored.selectedChat?.draft, "Other draft")
    }

    func testProjectsThreadsAndSelectionSurviveRestart() async throws {
        let root = try directory()
        let workspace = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        await workspace.restore()
        let projectID = try await workspace.createProject(name: "Example", directory: root)
        let first = try XCTUnwrap(workspace.selectedThreadID)
        let firstChat = try XCTUnwrap(workspace.selectedChat)
        firstChat.draft = "First draft"
        let model = ChatModelOption(connection: ProviderConnection(name: "Test", provider: .openAI, modelID: "gpt-5"))
        firstChat.select(model)
        await workspace.createThread(in: projectID)
        let second = try XCTUnwrap(workspace.selectedThreadID)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(workspace.selectedChat?.draft.isEmpty == true)
        workspace.selectedChat?.synchronizeModel(models: [model])
        XCTAssertNil(workspace.selectedChat?.selectedModel)
        workspace.selectedChat?.draft = "Second draft"
        await workspace.renameThread(second, to: "Investigate a failure")
        await workspace.select(first)
        await workspace.shutdown()
        let restored = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        await restored.restore()
        XCTAssertEqual(restored.threads.count, 2)
        XCTAssertEqual(restored.selectedThreadID, first)
        XCTAssertEqual(restored.threads.last?.title, "Investigate a failure")
        XCTAssertEqual(restored.selectedChat?.draft, "First draft")
        restored.selectedChat?.synchronizeModel(models: [model])
        XCTAssertEqual(restored.selectedChat?.selectedModel, model)
        await restored.select(second)
        XCTAssertEqual(restored.selectedChat?.draft, "Second draft")
    }

    func testLegacyWorkspaceDataIsIgnoredButSettingsSurvive() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("workspace.sqlite")
        let old = try StateDatabase(url: file, migrations: ["""
            CREATE TABLE projects (payload TEXT NOT NULL);
            INSERT INTO projects VALUES ('old project');
            CREATE TABLE settings (key TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL);
            INSERT INTO settings VALUES ('appearance', '"dark"');
            """], schema: ["projects": ["payload"], "settings": ["key", "payload"]])
        let workspace = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        await workspace.restore()
        XCTAssertTrue(workspace.projects.isEmpty)
        XCTAssertTrue(workspace.canSave)
        XCTAssertEqual(AppSettings(database: workspace.database).appearance, "dark")
        try await workspace.createProject(name: "Fresh", directory: root)
        XCTAssertEqual(try old.query("SELECT payload FROM projects"), [["payload": .text("old project")]])
        let restored = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        await restored.restore()
        XCTAssertEqual(restored.projects.first?.name, "Fresh")
    }

    func testUnreadableWorkspaceCannotBeOverwritten() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("projects.sqlite")
        try Data("invalid".utf8).write(to: file)
        let workspace = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        await workspace.restore()
        XCTAssertFalse(workspace.canSave)
        XCTAssertNotNil(workspace.error)
        do {
            try await workspace.createProject(name: "New", directory: root)
            XCTFail("An unreadable workspace must reject writes.")
        } catch {}
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "invalid")
    }

    func testDuplicateProjectFolderIsRejected() async throws {
        let root = try directory()
        let workspace = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        await workspace.restore()
        try await workspace.createProject(name: "One", directory: root)
        do {
            try await workspace.createProject(name: "Two", directory: root.appendingPathComponent("."))
            XCTFail("Normalized duplicate folder was accepted.")
        } catch { XCTAssertEqual(error.localizedDescription, "This folder is already in your projects.") }
        XCTAssertEqual(workspace.projects.count, 1)
    }

    func testDefaultProjectFolderNamesStayWithinDocumentsFritz() {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Fritz")
        for (name, leaf) in [
            ("  My Project  ", "My-Project"),
            ("Notes/2026: plans\\draft?*<>|\"", "Notes-2026-plans-draft-"),
            ("Two\twords\nnext\u{0000}part", "Two-words-next-part"),
            ("../Outside", "-Outside"), (".", "Project"), ("..", "Project"),
            ("Café 日記", "Café-日記"),
        ] {
            XCTAssertEqual(WorkspaceStore.defaultProjectDirectory(name: name).path,
                           root.appendingPathComponent(leaf).path, name)
        }
    }

    func testDefaultFolderIsCreatedAndPersistedAcrossLaunch() async throws {
        let root = try directory()
        let workspace = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        await workspace.restore()
        let name = "Fritz-test-\(UUID()) My/Project"
        let folder = WorkspaceStore.defaultProjectDirectory(name: name)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let project = try await workspace.createProject(name: name)
        let restored = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        await restored.restore()
        XCTAssertEqual(restored.selectedProject?.id, project)
        XCTAssertEqual(restored.selectedChat?.projectPath, folder.resolvingSymlinksInPath().path)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testUserStopRemainsDistinctFromProviderInterruptionAfterReload() async throws {
        let root = try directory()
        let repository = ProjectRepository(directory: root)
        let selection = try await repository.createProject(name: "Test", directory: root, defaultDirectory: root)
        let script = #"""
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            if request["method"] == "chat":
                print(json.dumps({"id": request["id"], "type": "error", "message": "Provider disconnected"}), flush=True)
        """#
        let agent = AgentClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                                arguments: ["-u", "-c", script], environment: ["PATH": "/usr/bin:/bin"])
        agent.start()
        defer { agent.stop() }

        let chat = ChatStore(agent: agent, repository: repository, threadID: selection.thread.id,
                             projectPath: selection.project.directory)
        await chat.restore()
        chat.select(ChatModelOption(connection: ProviderConnection(name: "Mock", provider: .openAICompatible, modelID: "fixture")))

        for stopsByUser in [true, false] {
            let completed = expectation(description: stopsByUser ? "User stop was saved" : "Provider interruption was saved")
            chat.onIdle = { completed.fulfill() }
            chat.onFirstPrompt = stopsByUser ? { [weak chat] in chat?.stopByUser() } : nil
            chat.draft = "Test response"
            chat.send()
            await fulfillment(of: [completed], timeout: 2)
            XCTAssertEqual(chat.messages.last?.wasStoppedByUser, stopsByUser)
            XCTAssertEqual(chat.error, stopsByUser ? nil : "Provider disconnected")
        }

        let restored = ProjectRepository(directory: root)
        let messages = try await restored.transcript(selection.thread.id)
        let responses = messages.filter { $0.role == "assistant" }
        XCTAssertEqual(responses.map(\.wasStoppedByUser), [false, true])
        XCTAssertTrue(responses.allSatisfy { !$0.isComplete && $0.elapsedTime != nil })
    }

    func testInterruptedTurnRetainsTextAndReceiptsAndDoesNotReplayUnknownOutcome() async throws {
        let root = try directory()
        let repository = ProjectRepository(directory: root)
        let item = try await repository.createProject(name: "Test", directory: root, defaultDirectory: root)
        let id = item.thread.id
        let turn = UUID()
        let model = ChatModelOption(connection: ProviderConnection(name: "Mock", provider: .openAICompatible, modelID: "fixture"))
        _ = try await repository.beginTurn(thread: id, turn: turn, prompt: "Hello", preferences: .init(),
                                           model: model, projectPath: item.project.directory)
        try await repository.checkpoint(turn: turn, text: "Partial", tool: .init(id: "call", name: "edit_file",
                                                                                summary: "hello.txt", arguments: "{}"))
        let restored = ProjectRepository(directory: root)
        let entries = try await restored.transcript(id)
        XCTAssertEqual(entries.map(\.content), ["Partial", "Hello"])
        XCTAssertFalse(try XCTUnwrap(entries.first).isComplete)
        let receipt = try await restored.tool(turn, callID: "call")
        XCTAssertNil(receipt?.success)
        let next = try await restored.beginTurn(thread: id, turn: UUID(), prompt: "Continue",
                                                preferences: .init(), model: model, projectPath: item.project.directory)
        XCTAssertTrue(next.context.contains { $0.content.contains("Outcome unknown") })
        XCTAssertTrue(next.context.allSatisfy { $0.tools.isEmpty })
        try await restored.delete(id)
        let deleted = try await restored.transcript(id)
        let deletedReceipt = try await restored.tool(turn, callID: "call")
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertNil(deletedReceipt)
    }

    func testLargeWorkspaceLoadsRecentAndDeepPagesAndLazilyLoadsLargePayloads() async throws {
        let root = try directory()
        let initializer = ProjectRepository(directory: root)
        _ = try await initializer.projects()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tests/fixtures/large_workspace.sql")
        let seed = Process()
        seed.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        seed.arguments = [root.appendingPathComponent("projects.sqlite").path]
        seed.standardInput = try FileHandle(forReadingFrom: fixture)
        try seed.run()
        seed.waitUntilExit()
        XCTAssertEqual(seed.terminationStatus, 0)

        let workspace = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        let start = ContinuousClock.now
        await workspace.restore()
        let restoreTime = start.duration(to: .now)
        XCTAssertNil(workspace.error)
        XCTAssertEqual(workspace.projects.count, 50)
        XCTAssertTrue(workspace.hasMoreProjects)
        XCTAssertTrue(workspace.hasMoreThreads)
        XCTAssertEqual(workspace.selectedProject?.name, "Fixture Project 5000")
        let chat = try XCTUnwrap(workspace.selectedChat)
        XCTAssertEqual(chat.draft, "Fixture draft")
        XCTAssertEqual(chat.messages.map(\.sequence), Array(99961...100000))
        await chat.older()
        XCTAssertEqual(chat.messages.first?.sequence, 99921)
        let last = try XCTUnwrap(chat.messages.last)
        XCTAssertTrue(last.hasMoreBody)
        XCTAssertLessThan(chat.messages.reduce(0) { $0 + $1.content.utf8.count }, 256 * 1024)
        let body = try await workspace.repository.body(last.id, from: 12)
        XCTAssertEqual(body.reduce(0) { $0 + $1.utf8.count }, 4 * 64 * 1024)
        let tool = try await workspace.repository.tool(last.id, callID: "fixture-tool")
        XCTAssertEqual(tool?.result?.utf8.count, 32000)
        for _ in 0..<6 { await chat.older() }
        XCTAssertEqual(chat.messages.count, 120)
        XCTAssertEqual(chat.messages.first?.sequence, 99681)
        XCTAssertTrue(chat.hasNewer)
        await chat.newer()
        XCTAssertEqual(chat.messages.first?.sequence, 99721)
        await chat.latest()
        XCTAssertEqual(chat.messages.map(\.sequence), Array(99961...100000))

        let thread = try XCTUnwrap(workspace.selectedThreadID)
        var latencies: [Duration] = []
        for cursor: Int64 in [99960, 90001, 80001, 70001, 60001, 50001, 40001, 30001, 20001, 10001, 1001] {
            let start = ContinuousClock.now
            let page = try await workspace.repository.transcript(thread, before: cursor)
            latencies.append(start.duration(to: .now))
            XCTAssertEqual(page.prefix(40).map(\.sequence), Array((cursor-40..<cursor).reversed()))
        }
        print("Large workspace restore: \(restoreTime). Warm transcript page p95: \(latencies.sorted().last ?? .zero).")
        await workspace.pageProjects(forward: true)
        XCTAssertEqual(workspace.projects.first?.position, 51)
        XCTAssertEqual(workspace.selectedThreadID, thread)
        await workspace.pageThreads(forward: true)
        XCTAssertTrue(workspace.threads.allSatisfy { !$0.isArchived })

        let model = ChatModelOption(connection: ProviderConnection(name: "Mock", provider: .openAICompatible, modelID: "fixture"))
        let prepared = try await workspace.repository.beginTurn(thread: thread, turn: UUID(), prompt: "Continue",
                                                                 preferences: .init(), model: model, projectPath: nil)
        XCTAssertEqual(prepared.sequence, 100001)
        XCTAssertLessThan(try JSONEncoder().encode(prepared.context).count, 1_000_000)
        XCTAssertEqual(prepared.context.last?.content, "Continue")
    }
    func testCompactedContextIsRestoredForTheSameHarnessSettings() async throws {
        let root = try directory()
        let repository = ProjectRepository(directory: root)
        let project = try await repository.createProject(name: "Test", directory: nil, defaultDirectory: root)
        let thread = project.thread.id
        let model = ChatModelOption(connection: ProviderConnection(name: "Fixture", provider: .openAICompatible, modelID: "fixture"))
        let first = UUID()
        let history = String(repeating: "An earlier itinerary. ", count: 1_000)
        _ = try await repository.beginTurn(thread: thread, turn: first, prompt: history, preferences: .init(),
                                           model: model, projectPath: project.project.directory, contextKey: "settings-a")
        let terminal = TurnMetadata(complete: true, provider: model.provider, modelID: model.modelID)
        try await repository.checkpoint(turn: first, text: "Earlier response", terminal: terminal)
        let second = UUID()
        let full = try await repository.beginTurn(thread: thread, turn: second, prompt: "Second question",
                                                   preferences: .init(), model: model,
                                                   projectPath: project.project.directory, contextKey: "settings-a")
        XCTAssertEqual(full.context.first?.content, history)
        try await repository.saveContextSummary(thread: thread, key: "settings-a",
                                                through: full.sequence - 1, summary: "Saved context")
        try await repository.checkpoint(turn: second, text: "Second response", terminal: terminal)

        let restored = ProjectRepository(directory: root)
        let third = UUID()
        let compacted = try await restored.beginTurn(thread: thread, turn: third, prompt: "Third question",
                                                      preferences: .init(), model: model,
                                                      projectPath: project.project.directory, contextKey: "settings-a")
        XCTAssertTrue(compacted.hasPreviousSummary)
        XCTAssertEqual(compacted.context.map(\.content), ["Saved context", "Second question", "Second response", "Third question"])
        try await restored.checkpoint(turn: third, text: "Third response", terminal: terminal)
        let changed = try await restored.beginTurn(thread: thread, turn: UUID(), prompt: "Fourth question",
                                                    preferences: .init(), model: model,
                                                    projectPath: project.project.directory, contextKey: "settings-b")
        XCTAssertFalse(changed.hasPreviousSummary)
        XCTAssertEqual(changed.context.first?.content, history)
    }

    func testSettingsAndRecentsAreIsolatedAndSurviveRestart() throws {
        let root = try directory()
        let database = AppDatabase(directory: root)
        let settings = AppSettings(database: database)
        settings.appearance = "dark"
        settings.updateChannel = "beta"
        settings.selectedTab = "harness"
        settings.harness.automaticCompaction = false
        settings.harness.contextTokens = 32_768
        settings.harness.reserveTokens = 4_096
        settings.harness.keepRecentTokens = 8_192
        let previous = AppSettings(database: AppDatabase(directory: root))
        XCTAssertNil(previous.harness.requestParameters["quantizeLocalKVCache"])
        XCTAssertEqual(previous.harness.contextTokens, 32_768)
        settings.harness.quantizeLocalKVCache = true
        let providers = ProviderStore(agent: AgentClient(), database: database)
        let localModels = LocalModelRuntimeStore(agent: AgentClient(), database: database)
        XCTAssertEqual(localModels.policy(for: "model-a"), .firstUse)
        try localModels.setPolicy(.appStart, for: "model-a")
        providers.record(ChatModelOption(id: "chosen", displayName: "Chosen", provider: .openAI, modelID: "gpt-5"))
        let restoredDatabase = AppDatabase(directory: root)
        let restored = AppSettings(database: restoredDatabase)
        XCTAssertEqual(restored.appearance, "dark")
        XCTAssertEqual(restored.updateChannel, "beta")
        XCTAssertEqual(restored.selectedTab, "harness")
        XCTAssertEqual(restored.harness, settings.harness)
        XCTAssertEqual(restored.harness.requestParameters["quantizeLocalKVCache"] as? Bool, true)
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

    func testProviderCategoriesDistinguishCustomEndpointsAndHostedPresets() {
        XCTAssertTrue(AIProviderCategory.system1.contains(.adapter(.jev)))
        XCTAssertTrue(AIProviderCategory.system1.contains(.adapter(.ollaya)))
        XCTAssertFalse(AIProviderCategory.system1.contains(.adapter(.openAI)))
        XCTAssertFalse(AIProviderCategory.local.contains(.adapter(.ollama)))
        XCTAssertTrue(AIProviderCategory.remote.contains(.adapter(.ollama)))
        XCTAssertTrue(AIProviderCategory.hosted.contains(.fireworks))
        XCTAssertFalse(AIProviderCategory.custom.contains(.fireworks))
        XCTAssertTrue(AIProviderCategory.custom.contains(.adapter(.openAICompatible)))
        XCTAssertTrue(AIProviderCategory.frontier.contains(.adapter(.anthropic)))
    }
}
