import Fritz
import Foundation
import Observation

@MainActor @Observable final class WorkspaceStore {
    private(set) var document = WorkspaceDocument()
    var error: String?
    private(set) var canSave = true
    private var unavailableProjects: Set<UUID> = []
    let database: AppDatabase
    let modelCatalog: RemoteModelCatalog
    @ObservationIgnored private let agent: AgentClient
    @ObservationIgnored private var chats: [UUID: ChatStore] = [:]

    init(agent: AgentClient, dataDirectory: URL = FritzPaths.data) {
        self.agent = agent
        self.database = AppDatabase(directory: dataDirectory)
        self.modelCatalog = RemoteModelCatalog(cacheURL: dataDirectory.appendingPathComponent("model-catalog-cache.json"))
        do {
            document = try database.loadWorkspace()
        } catch {
            self.error = "Could not restore projects: \(error.localizedDescription)"
            canSave = false
        }
    }

    var projects: [FritzProject] { document.projects }
    var canCreateThread: Bool {
        canSave && (selectedProject.map { isAvailable($0) } ?? projects.contains(where: { isAvailable($0) }))
    }
    var selectedThreadID: UUID? { document.selectedThreadID }
    var selectedProject: FritzProject? {
        projects.first { project in project.threads.contains { $0.id == selectedThreadID } }
    }
    var selectedThread: ProjectThread? {
        selectedProject?.threads.first { $0.id == selectedThreadID }
    }
    var selectedChat: ChatStore? {
        guard let project = selectedProject, isAvailable(project), let id = selectedThreadID else { return nil }
        return chat(for: id)
    }

    static func directoryIsAvailable(_ path: String?) -> Bool {
        guard let path else { return true }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            && directory.boolValue && FileManager.default.isReadableFile(atPath: path)
            && FileManager.default.isExecutableFile(atPath: path)
    }

    func isAvailable(_ project: FritzProject) -> Bool {
        _ = unavailableProjects
        return Self.directoryIsAvailable(project.directory)
    }

    func refreshAvailability() {
        let unavailable = Set(projects.filter { !Self.directoryIsAvailable($0.directory) }.map(\.id))
        let newlyUnavailable = unavailable.subtracting(unavailableProjects)
        if unavailable != unavailableProjects { unavailableProjects = unavailable }
        for project in projects where newlyUnavailable.contains(project.id) {
            for thread in project.threads { chats[thread.id]?.stop(); chats[thread.id]?.savePreferences() }
        }
    }

    func repairProject(_ id: UUID, directory: URL? = nil) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        guard let path = directory?.standardizedFileURL.resolvingSymlinksInPath().path ?? projects[index].directory else {
            throw AgentFailure(message: "Choose a project folder.")
        }
        guard !projects.contains(where: { $0.id != id && $0.directory == path }) else {
            throw AgentFailure(message: "This folder is already in your projects.")
        }
        if directory == nil { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
        guard Self.directoryIsAvailable(path) else { throw AgentFailure(message: "Choose an accessible project folder.") }
        for thread in projects[index].threads {
            chats[thread.id]?.stop()
            chats[thread.id]?.savePreferences()
        }
        var next = document
        next.projects[index].directory = path
        try commit(next)
        for thread in projects[index].threads { chats.removeValue(forKey: thread.id) }
    }

    func setArchived(_ id: UUID, _ archived: Bool) {
        chats[id]?.stop()
        chats[id]?.savePreferences()
        guard let project = document.projects.firstIndex(where: { $0.threads.contains(where: { $0.id == id }) }),
              let thread = document.projects[project].threads.firstIndex(where: { $0.id == id }) else { return }
        var next = document
        next.projects[project].threads[thread].isArchived = archived
        if archived && next.selectedThreadID == id { next.selectedThreadID = nil }
        do { try commit(next) } catch { self.error = error.localizedDescription }
    }

    func deleteThread(_ id: UUID) {
        chats[id]?.stop()
        var next = document
        for index in next.projects.indices { next.projects[index].threads.removeAll { $0.id == id } }
        if next.selectedThreadID == id { next.selectedThreadID = nil }
        do {
            try commit(next)
            chats.removeValue(forKey: id)
        } catch { self.error = error.localizedDescription }
    }

    func clearSelection() {
        var next = document
        next.selectedThreadID = nil
        do { try commit(next) } catch { self.error = error.localizedDescription }
    }

    func chat(for id: UUID) -> ChatStore {
        if let chat = chats[id] { return chat }
        let project = projects.first { $0.threads.contains { $0.id == id } }
        let chat = ChatStore(agent: agent, database: database, threadID: id, projectPath: project?.directory, modelCatalog: modelCatalog)
        chat.onFirstPrompt = { [weak self] prompt in self?.nameThread(id, from: prompt) }
        chats[id] = chat
        return chat
    }

    func select(_ id: UUID?) {
        guard let id, projects.contains(where: { isAvailable($0) && $0.threads.contains(where: { $0.id == id }) }) else { return }
        selectedChat?.savePreferences()
        var next = document
        next.selectedThreadID = id
        do { try commit(next) } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    func createProject(name: String, directory: URL? = nil) throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AgentFailure(message: "Enter a project name.") }
        guard canSave else { throw AgentFailure(message: "The workspace could not be loaded. The database has been preserved.") }
        let usesDefault = directory == nil
        let directory = (directory ?? Self.defaultProjectDirectory(name: name)).standardizedFileURL.resolvingSymlinksInPath()
        guard !projects.contains(where: { $0.directory == directory.path }) else {
            throw AgentFailure(message: "This folder is already in your projects.")
        }
        if usesDefault {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AgentFailure(message: "Choose an existing project folder.")
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

    static func defaultProjectDirectory(name: String) -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Fritz", isDirectory: true)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return root }
        // Keep the display name intact while preventing separators, control characters,
        // and special path components from becoming the folder name.
        let safeName = name.replacingOccurrences(of: #"[\s/\\:<>"|?*\p{Cc}]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return root.appendingPathComponent(safeName.isEmpty ? "Project" : safeName, isDirectory: true)
    }

    func createThread(in projectID: UUID) {
        guard let index = document.projects.firstIndex(where: { $0.id == projectID }), isAvailable(document.projects[index]) else { return }
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
