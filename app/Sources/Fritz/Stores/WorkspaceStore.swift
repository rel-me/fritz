import Fritz
import Foundation
import Observation

@MainActor @Observable final class WorkspaceStore {
    private(set) var projects: [FritzProject] = []
    private(set) var threads: [ProjectThread] = []
    private(set) var expandedProjectID: UUID?
    private(set) var selectedProject: FritzProject?
    private(set) var selectedThread: ProjectThread?
    private(set) var selectedChat: ChatStore?
    private(set) var canSave = false
    private(set) var isEditing = false
    private(set) var isLoading = true
    private(set) var showArchived = false
    private(set) var hasMoreProjects = false
    private(set) var hasMoreThreads = false
    private(set) var projectCursors: [Int64] = [0]
    private(set) var threadCursors: [Int64] = [0]
    var error: String?

    let database: AppDatabase
    let repository: ProjectRepository
    let modelCatalog: RemoteModelCatalog
    @ObservationIgnored private let agent: AgentClient
    @ObservationIgnored private var chats: [UUID: (UUID, ChatStore)] = [:]
    @ObservationIgnored private var availabilityCheck = false
    @ObservationIgnored private var projectRevision = 0
    @ObservationIgnored private var threadRevision = 0
    @ObservationIgnored private var pendingSelection: UUID?
    private var unavailableProjects: Set<UUID> = []
    private var projectPageEnd: Int64?
    private var threadPageEnd: Int64?

    init(agent: AgentClient, dataDirectory: URL = FritzPaths.data) {
        self.agent = agent
        database = AppDatabase(directory: dataDirectory)
        repository = ProjectRepository(directory: dataDirectory)
        modelCatalog = RemoteModelCatalog(cacheURL: dataDirectory.appendingPathComponent("model-catalog-cache.json"))
    }

    func restore() async {
        guard isLoading, !isEditing else { return }
        isEditing = true
        defer { isEditing = false; isLoading = false }
        do {
            let selection = try await repository.selection()
            selectedProject = selection?.project
            selectedThread = selection?.thread
            showArchived = selection?.thread.isArchived == true
            expandedProjectID = selection?.project.id
            try await loadProjects()
            try await loadThreads()
            await refreshAvailability()
            await show(selection)
            canSave = true
        } catch { self.error = "Could not restore projects: \(error.localizedDescription)" }
    }

    var selectedThreadID: UUID? { selectedThread?.id }
    var canCreateThread: Bool {
        canSave && !isEditing && (selectedProject.map { isAvailable($0) } ?? projects.contains { isAvailable($0) })
    }

    func isAvailable(_ project: FritzProject) -> Bool {
        !unavailableProjects.contains(project.id)
    }

    func refreshAvailability() async {
        guard !availabilityCheck else { return }
        availabilityCheck = true
        defer { availabilityCheck = false }
        let revision = projectRevision
        var indexed = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        if let selectedProject { indexed[selectedProject.id] = selectedProject }
        for (projectID, chat) in chats.values {
            guard chat.isResponding, indexed[projectID] == nil else { continue }
            if let project = try? await repository.lookup(chat.threadID)?.project { indexed[projectID] = project }
        }
        let unavailable = await repository.unavailable(Array(indexed.values))
        guard revision == projectRevision else { return }
        unavailableProjects = unavailable
        for (id, chat) in Array(chats.values) where unavailable.contains(id) { chat.stop() }
        if let selectedProject, let selectedThread {
            if unavailable.contains(selectedProject.id) {
                selectedChat = nil
                if let chat = chats[selectedThread.id]?.1 { _ = await chat.savePreferences() }
                pruneChats()
            } else if selectedChat == nil {
                await show(ProjectSelection(project: selectedProject, thread: selectedThread))
            }
        }
    }

    func expand(_ projectID: UUID, expanded: Bool) async {
        guard !isEditing, expanded || expandedProjectID == projectID else { return }
        await run {
            self.expandedProjectID = expanded ? projectID : nil
            self.threadCursors = [0]
            try await self.loadThreads()
        }
    }

    func setShowArchived(_ value: Bool) async {
        guard !isEditing else { return }
        await run {
            if !value && self.selectedThread?.isArchived == true {
                try await self.flushSelectedPreferences()
                try await self.repository.select(nil)
                await self.show(nil)
            }
            self.showArchived = value
            self.threadCursors = [0]
            try await self.loadThreads()
        }
    }

    func pageProjects(forward: Bool) async {
        guard !isEditing else { return }
        var cursors = projectCursors
        if forward, hasMoreProjects, let projectPageEnd { cursors.append(projectPageEnd) }
        else if !forward, cursors.count > 1 { cursors.removeLast() }
        else { return }
        await run {
            try await self.loadProjects(cursors: cursors)
            await self.refreshAvailability()
        }
    }

    func pageThreads(forward: Bool) async {
        guard !isEditing else { return }
        var cursors = threadCursors
        if forward, hasMoreThreads, let threadPageEnd { cursors.append(threadPageEnd) }
        else if !forward, cursors.count > 1 { cursors.removeLast() }
        else { return }
        await run { try await self.loadThreads(cursors: cursors) }
    }

    func select(_ id: UUID?) async {
        guard let id, canSave else { return }
        if isEditing {
            pendingSelection = id
            return
        }
        guard id != selectedThreadID else { return }
        await run {
            guard let selection = try await self.repository.lookup(id), self.isAvailable(selection.project) else { return }
            try await self.flushSelectedPreferences()
            try await self.repository.select(id)
            await self.show(selection)
            if self.expandedProjectID != selection.project.id {
                self.expandedProjectID = selection.project.id
                self.threadCursors = [0]
                try await self.loadThreads()
            }
        }
    }

    private func flushSelectedPreferences() async throws {
        if let selectedChat, !(await selectedChat.savePreferences()) {
            throw AgentFailure(message: "Could not save the current draft. Resolve the storage error and try again.")
        }
    }

    @discardableResult
    func createProject(name input: String, directory: URL? = nil) async throws -> UUID {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AgentFailure(message: "Enter a project name.") }
        guard canSave, !isEditing else { throw AgentFailure(message: "The project workspace is unavailable or busy.") }
        isEditing = true
        defer { isEditing = false; retrySelection() }
        try await flushSelectedPreferences()
        let selection = try await repository.createProject(name: name, directory: directory,
                                                           defaultDirectory: Self.defaultProjectDirectory(name: name))
        await showNew(selection)
        return selection.project.id
    }

    func createThread(in projectID: UUID) async {
        await run {
            try await self.flushSelectedPreferences()
            let selection = try await self.repository.createThread(in: projectID)
            await self.showNew(selection)
        }
    }

    private func showNew(_ selection: ProjectSelection) async {
        await show(selection)
        expandedProjectID = selection.project.id
        threadCursors = [0]
        do {
            try await loadProjects()
            try await loadThreads()
            await refreshAvailability()
        } catch { self.error = error.localizedDescription }
    }

    func renameProject(_ id: UUID, to input: String) async {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        await run {
            try await self.repository.renameProject(id, name: name)
            if let threadID = self.selectedThreadID, self.selectedProject?.id == id {
                self.selectedProject = try await self.repository.lookup(threadID)?.project
            }
            try await self.loadProjects()
        }
    }

    func renameThread(_ id: UUID, to input: String) async {
        let title = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        await run {
            try await self.repository.renameThread(id, title: title)
            try await self.refreshThread(id)
        }
    }

    func setArchived(_ id: UUID, _ archived: Bool) async {
        await run {
            await self.chats[id]?.1.finish()
            try await self.repository.archive(id, archived: archived)
            if archived, self.selectedThreadID == id { await self.show(nil) }
            try await self.loadThreads()
        }
    }

    func deleteThread(_ id: UUID) async {
        await run {
            await self.chats[id]?.1.finish()
            try await self.repository.delete(id)
            self.chats.removeValue(forKey: id)
            if self.selectedThreadID == id {
                self.selectedChat = nil
                await self.show(nil)
            }
            try await self.loadThreads()
        }
    }

    func repairProject(_ id: UUID, directory: URL?) async {
        await run {
            for (projectID, chat) in Array(self.chats.values) where projectID == id {
                await chat.finish()
                self.chats.removeValue(forKey: chat.threadID)
            }
            try await self.repository.repairProject(id, directory: directory)
            self.projectRevision += 1
            self.unavailableProjects.remove(id)
            if let threadID = self.selectedThreadID, self.selectedProject?.id == id {
                self.selectedChat = nil
                try await self.show(self.repository.lookup(threadID))
            }
            try await self.loadProjects()
        }
    }

    func shutdown() async {
        canSave = false
        // Stop all transports before waiting on any one thread's final write.
        let pending = Array(chats.values.map(\.1))
        for chat in pending { chat.stop() }
        for chat in pending { await chat.finish() }
    }

    private func show(_ selection: ProjectSelection?) async {
        let priorChat = selectedChat
        let chat: ChatStore?
        if let selection, isAvailable(selection.project) {
            let id = selection.thread.id
            if let existing = chats[id]?.1 {
                chat = existing
            } else {
                let created = ChatStore(agent: agent, repository: repository, threadID: id,
                                        projectPath: selection.project.directory, modelCatalog: modelCatalog)
                created.onFirstPrompt = { [weak self] in
                    Task {
                        do { try await self?.refreshThread(id) }
                        catch { self?.error = error.localizedDescription }
                    }
                }
                created.onIdle = { [weak self] in self?.pruneChats() }
                chats[id] = (selection.project.id, created)
                chat = created
            }
        } else { chat = nil }
        selectedProject = selection?.project
        selectedThread = selection?.thread
        selectedChat = chat
        if priorChat !== chat, let priorChat { _ = await priorChat.savePreferences() }
        pruneChats()
        await chat?.restore()
    }

    private func pruneChats() {
        // Retain only the selected view and in-flight requests. SQLite is the
        // inactive cache, so visits to thousands of threads cannot accumulate.
        chats = chats.filter { id, pair in id == selectedChat?.threadID || pair.1.isResponding }
    }

    private func refreshThread(_ id: UUID) async throws {
        if let fresh = try await repository.lookup(id), selectedThreadID == id {
            selectedThread = fresh.thread
        }
        if expandedProjectID != nil { try await loadThreads() }
    }

    private func loadProjects(cursors: [Int64]? = nil) async throws {
        projectRevision += 1
        let revision = projectRevision
        let cursors = cursors ?? projectCursors
        let page = try await repository.projects(after: cursors.last ?? 0)
        guard revision == projectRevision else { return }
        projectCursors = cursors
        projectPageEnd = page.rows.last?.position
        hasMoreProjects = page.hasMore
        projects = page.rows
    }

    private func loadThreads(cursors: [Int64]? = nil) async throws {
        threadRevision += 1
        let revision = threadRevision
        guard let id = expandedProjectID else {
            threads = []
            hasMoreThreads = false
            return
        }
        let cursors = cursors ?? threadCursors
        let page = try await repository.threads(in: id, after: cursors.last ?? 0, includeArchived: showArchived)
        guard revision == threadRevision else { return }
        threadCursors = cursors
        threadPageEnd = page.rows.last?.position
        hasMoreThreads = page.hasMore
        threads = page.rows
    }

    var sidebarProjects: [FritzProject] {
        guard let selectedProject, !projects.contains(where: { $0.id == selectedProject.id }) else { return projects }
        return projects + [selectedProject]
    }

    var sidebarThreads: [ProjectThread] {
        guard let selectedThread, selectedThread.projectID == expandedProjectID,
              showArchived || !selectedThread.isArchived,
              !threads.contains(where: { $0.id == selectedThread.id }) else { return threads }
        return threads + [selectedThread]
    }

    private func run(_ operation: () async throws -> Void) async {
        guard canSave, !isEditing else { return }
        isEditing = true
        error = nil
        defer { isEditing = false; retrySelection() }
        do { try await operation() }
        catch { self.error = error.localizedDescription }
    }

    private func retrySelection() {
        guard let pendingSelection else { return }
        self.pendingSelection = nil
        Task { await select(pendingSelection) }
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

}
