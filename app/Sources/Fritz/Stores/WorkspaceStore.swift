import Fritz
import Foundation
import Observation

@MainActor @Observable final class WorkspaceStore {
    private(set) var document = WorkspaceDocument()
    var error: String?
    private(set) var canSave = true
    let database: AppDatabase
    @ObservationIgnored private let agent: AgentClient
    @ObservationIgnored private var chats: [UUID: ChatStore] = [:]

    init(agent: AgentClient, dataDirectory: URL = FritzPaths.data) {
        self.agent = agent
        self.database = AppDatabase(directory: dataDirectory)
        do {
            document = try database.loadWorkspace()
        } catch {
            self.error = "Could not restore projects: \(error.localizedDescription)"
            canSave = false
        }
    }

    var projects: [FritzProject] { document.projects }
    var selectedThreadID: UUID? { document.selectedThreadID }
    var selectedProject: FritzProject? {
        projects.first { project in project.threads.contains { $0.id == selectedThreadID } }
    }
    var selectedThread: ProjectThread? {
        selectedProject?.threads.first { $0.id == selectedThreadID }
    }
    var selectedChat: ChatStore? { selectedThreadID.map { chat(for: $0) } }

    func chat(for id: UUID) -> ChatStore {
        if let chat = chats[id] { return chat }
        let project = projects.first { $0.threads.contains { $0.id == id } }
        let chat = ChatStore(agent: agent, database: database, threadID: id, projectPath: project?.directory)
        chat.onFirstPrompt = { [weak self] prompt in self?.nameThread(id, from: prompt) }
        chats[id] = chat
        return chat
    }

    func select(_ id: UUID?) {
        guard let id, projects.contains(where: { $0.threads.contains(where: { $0.id == id }) }) else { return }
        selectedChat?.savePreferences()
        var next = document
        next.selectedThreadID = id
        do { try commit(next) } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    func createProject(name: String, directory: URL) throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AgentFailure(message: "Enter a project name.") }
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AgentFailure(message: "Choose an existing project folder.")
        }
        guard !projects.contains(where: { $0.directory == directory.path }) else {
            throw AgentFailure(message: "This folder is already in your projects.")
        }
        let thread = ProjectThread()
        let project = FritzProject(name: name, directory: directory.path, threads: [thread])
        selectedChat?.savePreferences()
        var next = document
        next.projects.append(project)
        next.selectedThreadID = thread.id
        try commit(next)
        return project.id
    }

    func createThread(in projectID: UUID) {
        guard let index = document.projects.firstIndex(where: { $0.id == projectID }) else { return }
        selectedChat?.savePreferences()
        let thread = ProjectThread()
        var next = document
        next.projects[index].threads.append(thread)
        next.selectedThreadID = thread.id
        do { try commit(next) } catch { self.error = error.localizedDescription }
    }

    func renameThread(_ id: UUID, to title: String) {
        updateThread(id) { thread in
            thread.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            thread.titleIsAutomatic = false
        }
    }

    func renameProject(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = document.projects.firstIndex(where: { $0.id == id }) else { return }
        var next = document
        next.projects[index].name = name
        do { try commit(next) } catch { self.error = error.localizedDescription }
    }

    func shutdown() {
        for chat in chats.values { chat.stop(); chat.savePreferences() }
    }

    private func nameThread(_ id: UUID, from prompt: String) {
        updateThread(id) { thread in
            guard thread.titleIsAutomatic else { return }
            let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
            thread.title = String(line.prefix(56)) + (line.count > 56 ? "…" : "")
            thread.titleIsAutomatic = false
        }
    }

    private func updateThread(_ id: UUID, edit: (inout ProjectThread) -> Void) {
        guard let project = document.projects.firstIndex(where: { $0.threads.contains(where: { $0.id == id }) }),
              let thread = document.projects[project].threads.firstIndex(where: { $0.id == id }) else { return }
        var next = document
        edit(&next.projects[project].threads[thread])
        guard !next.projects[project].threads[thread].title.isEmpty else { return }
        do { try commit(next) } catch { self.error = error.localizedDescription }
    }

    private func commit(_ next: WorkspaceDocument) throws {
        guard canSave else { throw AgentFailure(message: "The workspace could not be loaded. The database has been preserved.") }
        try next.validate()
        try database.saveWorkspace(next)
        document = next
        error = nil
    }
}
