import Fritz
@testable import FritzApp
import SwiftUI
import XCTest

@MainActor
final class AppDialogSnapshots: XCTestCase {
    func testProjectDialogs() async throws {
        try DialogSnapshot.requireEnabled()
        let root = try temporaryDirectory()
        let workspace = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        await workspace.restore()
        try await snapshot(NewProjectSheet(workspace: workspace), named: "new-project-empty")
        try await snapshot(RenameItemSheet(item: .init(id: UUID(), title: "Sample project", isProject: true),
                                           save: { _ in }), named: "rename-project")
        try await snapshot(RenameItemSheet(item: .init(id: UUID(), title: "Planning notes", isProject: false),
                                           save: { _ in }), named: "rename-thread")
    }

    func testBrowserImportDialog() async throws {
        try DialogSnapshot.requireEnabled()
        let root = try temporaryDirectory()
        let profile = root.appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false)
        try Data().write(to: profile.appendingPathComponent("Cookies"))
        try Data().write(to: profile.appendingPathComponent("Login Data"))
        let source = BrowserImportSource(directory: profile, browser: "Sample Browser", service: "fixture", keychainAccount: "fixture")

        for appearance in DialogSnapshot.appearances {
            let actions = BrowserDataActions()
            try await DialogSnapshot.withSheet(BrowserImportSheet(actions: actions), appearance: appearance) { sheet in
                let empty = try await DialogSnapshot.check(sheet, name: "browser-import-empty", appearance: appearance)
                actions.sources = [source]
                let ready = try await DialogSnapshot.check(sheet, name: "browser-import-ready", appearance: appearance)
                XCTAssertGreaterThan(ready.height, empty.height)
                actions.message = "The profile is locked. Close the source browser and retry the import."
                let failed = try await DialogSnapshot.check(sheet, name: "browser-import-error", appearance: appearance)
                XCTAssertGreaterThan(failed.height, ready.height)
            }
        }
    }

    func testBrowserPasswordDialog() async throws {
        try DialogSnapshot.requireEnabled()
        let page = BrowserPage()
        defer { page.close() }
        page.load(URL(string: "http://127.0.0.1:1")!)
        page.stop()
        let origin = "http://127.0.0.1:1"
        for appearance in DialogSnapshot.appearances {
            let actions = BrowserDataActions()
            actions.message = "No imported passwords for \(origin)."
            try await DialogSnapshot.withSheet(BrowserPasswordSheet(actions: actions, page: page), appearance: appearance) { sheet in
                let empty = try await DialogSnapshot.check(sheet, name: "browser-password-empty", appearance: appearance)
                actions.message = nil
                actions.accounts = [.init(origin: origin, username: "sample@example.com"), .init(origin: origin, username: "")]
                let accounts = try await DialogSnapshot.check(sheet, name: "browser-password-accounts", appearance: appearance)
                XCTAssertGreaterThan(accounts.height, empty.height)
            }
        }
    }

    func testStoredMessageDialog() async throws {
        try DialogSnapshot.requireEnabled()
        let root = try temporaryDirectory()
        let workspace = WorkspaceStore(agent: AgentClient(), dataDirectory: root)
        await workspace.restore()
        _ = try await workspace.createProject(name: "Sample project", directory: root)
        let thread = try XCTUnwrap(workspace.selectedThreadID)
        let body = "This is the stored body of a sample message.\n\nIt contains multiple paragraphs."
        let model = ChatModelOption(connection: ProviderConnection(name: "Example", provider: .openAICompatible, modelID: "fixture"))
        let turn = try await workspace.repository.beginTurn(thread: thread, turn: UUID(), prompt: body,
                                                            preferences: .init(), model: model, projectPath: root.path)
        let entry = ChatMessage(id: turn.user, sequence: turn.sequence, role: "user", content: body)
        try await snapshot(ChatStoredBody(entry: entry, repository: workspace.repository), named: "stored-message-body")
    }

    private func snapshot<Content: View>(_ content: Content, named name: String) async throws {
        for appearance in DialogSnapshot.appearances {
            try await DialogSnapshot.withSheet(content, appearance: appearance) { sheet in
                try await DialogSnapshot.check(sheet, name: name, appearance: appearance)
            }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fritz-dialog-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
}
