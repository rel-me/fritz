import Foundation
import Fritz
import Observation

struct ChatMessage: Identifiable, Equatable, Sendable {
    var id: UUID
    var sequence: Int64
    var role: String
    var content: String
    var isComplete = true
    var wasStoppedByUser = false
    var hasMoreBody = false
    var toolCount = 0
    var elapsedTime: TimeInterval?
    var usageSummary: ChatResponseUsageSummary?
}

struct ChatToolActivity: Identifiable, Sendable {
    let id: String
    let name: String
    let summary: String
    var arguments = ""
    var result: String?
    var success: Bool?
}

struct ChatPreferences: Codable, Equatable, Sendable {
    var draft = ""
    var connectionID: UUID?
    var modelID: String?
    var effort: ChatReasoningEffort = .medium
    var speed: ChatSpeed = .standard
}

struct TurnMetadata: Codable, Sendable {
    let complete: Bool
    let provider: AIProviderKind
    let modelID: String
    var elapsedTime: TimeInterval?
    var usageSummary: ChatResponseUsageSummary?
    var wasStoppedByUser: Bool?
}

struct ContextToolExchange: Codable, Sendable {
    let id: String
    let name: String
    let arguments: String
    let result: String
    let failed: Bool
}

struct ContextMessage: Encodable, Sendable {
    let role: String
    let content: String
    var tools: [ContextToolExchange] = []
    var sequence: Int64?

    enum CodingKeys: String, CodingKey { case role, content, tools }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(role, forKey: .role)
        try values.encode(content, forKey: .content)
        if !tools.isEmpty { try values.encode(tools, forKey: .tools) }
    }
}

struct PreparedTurn: Sendable {
    let user: UUID
    let sequence: Int64
    let context: [ContextMessage]
    let hasPreviousSummary: Bool
}

private struct CompactionReceipt: Decodable {
    let prefixMessages: Int
}

@MainActor @Observable final class ChatStore {
    var draft = "" { didSet { schedulePreferences() } }
    private(set) var messages: [ChatMessage] = []
    private(set) var isResponding = false
    private(set) var isReady = false
    private(set) var isPaging = false
    private(set) var hasOlder = false
    private(set) var hasNewer = false
    private(set) var windowRevision = 0
    var error: String?
    var selectedModel: ChatModelOption?
    var effort: ChatReasoningEffort = .medium { didSet { schedulePreferences() } }
    var speed: ChatSpeed = .standard { didSet { schedulePreferences() } }
    var responseTokens: Int?
    private(set) var activity: String?
    private(set) var localModelStatus: LocalModelStatus?
    private(set) var activeTools: [ChatToolActivity] = []
    let projectPath: String?
    let agent: AgentClient
    let repository: ProjectRepository
    let threadID: UUID

    @ObservationIgnored var onFirstPrompt: (() -> Void)?
    @ObservationIgnored var onIdle: (() -> Void)?
    @ObservationIgnored private var loadedPreferences = ChatPreferences()
    @ObservationIgnored private var savedPreferences = ChatPreferences()
    @ObservationIgnored private var preferenceTask: Task<Void, Never>?
    @ObservationIgnored private var responseTask: Task<Void, Never>?
    @ObservationIgnored private var requestID: UUID?
    private enum StopReason { case user, automatic }
    @ObservationIgnored private var stopReason: StopReason?
    private var stopRequested: Bool { stopReason != nil }
    @ObservationIgnored private var isStartingTurn = false
    @ObservationIgnored private var pendingText = ""
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var activeMessage: ChatMessage?
    @ObservationIgnored private var responseUsage = ChatUsage()
    @ObservationIgnored private var loadGeneration = 0
    private var storageFailure = false
    private let modelCatalog: RemoteModelCatalog
    private let appSettings: AppSettings?

    init(agent: AgentClient, repository: ProjectRepository, threadID: UUID, projectPath: String? = nil,
         modelCatalog: RemoteModelCatalog? = nil, appSettings: AppSettings? = nil) {
        self.agent = agent
        self.repository = repository
        self.threadID = threadID
        self.projectPath = projectPath
        self.modelCatalog = modelCatalog ?? RemoteModelCatalog()
        self.appSettings = appSettings
    }

    func restore() async {
        guard !isReady else { return }
        do {
            let preferences = try await repository.preferences(for: threadID) ?? ChatPreferences()
            let page = try await repository.transcript(threadID)
            loadedPreferences = preferences
            savedPreferences = preferences
            draft = preferences.draft
            effort = preferences.effort
            speed = preferences.speed
            setLatest(page)
            isReady = true
        } catch { self.error = "Could not restore the conversation: \(error.localizedDescription)" }
    }

    var activeEntryID: UUID? { isResponding ? requestID : nil }

    var canSend: Bool {
        isReady && !storageFailure && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedModel?.connectionID != nil && agent.isRunning && !isResponding
    }

    func synchronizeModel(models: [ChatModelOption], defaultModel: ChatModelOption?) {
        if let provider = loadedPreferences.connectionID, let model = loadedPreferences.modelID,
           let saved = models.first(where: { $0.connectionID == provider && $0.modelID == model }) {
            select(saved, restoring: true)
        } else if let defaultModel {
            select(defaultModel)
        } else {
            selectedModel = nil
        }
    }

    func select(_ model: ChatModelOption, restoring: Bool = false) {
        guard !isResponding else { return }
        let initial = loadedPreferences.modelID == nil && !restoring
        selectedModel = model
        loadedPreferences.connectionID = model.connectionID
        loadedPreferences.modelID = model.modelID
        if initial || (model.capabilities.supportsReasoningEffort && !model.capabilities.reasoningEfforts.contains(effort)) {
            effort = model.defaultReasoning ?? .medium
        }
        if initial || !model.capabilities.supportedSpeeds.contains(speed) { speed = model.defaultSpeed }
        schedulePreferences()
    }

    func send() {
        guard canSend, let model = selectedModel, let connectionID = model.connectionID else { return }
        error = nil
        responseTokens = nil
        activity = "Starting…"
        responseUsage = ChatUsage()
        activeTools = []
        pendingText = ""
        stopReason = nil
        let harness = appSettings?.harness ?? HarnessSettings()
        let originalDraft = draft
        let prompt = originalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        var committedPreferences = preferences
        committedPreferences.draft = ""
        let turn = UUID()
        requestID = turn
        isResponding = true
        isStartingTurn = true
        preferenceTask?.cancel()
        responseTask = Task {
            let started = Date()
            var complete = false
            var persisted = false
            do {
                if let preferenceTask { await preferenceTask.value }
                let contextKey = harness.automaticCompaction
                    ? "\(connectionID.uuidString)/\(model.modelID)/\(harness.contextTokens)/\(harness.reserveTokens)/\(harness.keepRecentTokens)"
                    : nil
                let prepared = try await repository.beginTurn(thread: threadID, turn: turn, prompt: prompt,
                    preferences: committedPreferences, model: model, projectPath: projectPath, contextKey: contextKey)
                persisted = true
                savedPreferences = committedPreferences
                if draft == originalDraft { draft = "" }
                isStartingTurn = false
                schedulePreferences()
                let user = ChatMessage(id: prepared.user, sequence: prepared.sequence, role: "user",
                                       content: ProjectRepository.prefix(prompt, bytes: ProjectRepository.previewBytes),
                                       hasMoreBody: prompt.utf8.count > ProjectRepository.previewBytes)
                let assistant = ChatMessage(id: turn, sequence: prepared.sequence + 1, role: "assistant",
                                            content: "", isComplete: false)
                activeMessage = assistant
                loadGeneration += 1
                if hasNewer { setLatest(try await repository.transcript(threadID)) }
                else {
                    messages.append(contentsOf: [user, assistant])
                    trimFromStart()
                }
                onFirstPrompt?()
                if !stopRequested {
                    let history = try JSONEncoder().encode(prepared.context)
                    var contextParams = harness.requestParameters
                    contextParams["hasPreviousSummary"] = prepared.hasPreviousSummary
                    if let context = model.context, context.source == .provider {
                        contextParams["reportedContext"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(context))
                    }
                    var params: [String: Any] = [
                        "connectionId": connectionID.uuidString, "model": model.modelID,
                        "messages": try JSONSerialization.jsonObject(with: history),
                        "historyVersion": 2, "context": contextParams,
                    ]
                    if let projectPath { params["projectPath"] = projectPath }
                    if model.capabilities.supportsReasoningEffort { params["effort"] = effort.rawValue }
                    if model.capabilities.supportsSpeed { params["speed"] = speed.rawValue }
                    if model.provider == .fritz {
                        localModelStatus = LocalModelStatus(id: model.modelID, name: model.displayName, phase: .starting)
                    }
                    for try await data in agent.stream(method: "chat", params: params, id: turn.uuidString) {
                        if stopRequested { break }
                        let event = try JSONDecoder().decode(AgentEvent.self, from: data)
                        if event.type == "context_compacted", let contextKey, let summary = event.summary {
                            let receipt = try JSONDecoder().decode(CompactionReceipt.self, from: data)
                            if receipt.prefixMessages > 0, receipt.prefixMessages < prepared.context.count,
                               let through = prepared.context[receipt.prefixMessages].sequence {
                                try await repository.saveContextSummary(thread: threadID, key: contextKey,
                                                                        through: through - 1, summary: summary)
                            }
                        } else {
                            try await handle(event, data: data, turn: turn, model: model)
                        }
                    }
                    complete = !stopRequested && activeMessage?.content.isEmpty == false
                    if !stopRequested && !complete { error = "The provider returned an empty response. Try another model." }
                }
            } catch {
                if !stopRequested || !persisted { self.error = error.localizedDescription }
                if persisted && !stopRequested { agent.cancel(turn.uuidString) }
            }
            localModelStatus = nil
            isStartingTurn = false
            flushTask?.cancel()
            if let flushTask { await flushTask.value }
            flushTask = nil
            if persisted {
                let elapsed = max(0, Date().timeIntervalSince(started))
                let usage = modelCatalog.summary(usage: responseUsage, provider: model.provider,
                    modelID: model.modelID, modelName: model.displayName, speed: committedPreferences.speed)
                let wasStoppedByUser = !complete && stopReason == .user
                let terminal = TurnMetadata(complete: complete, provider: model.provider, modelID: model.modelID,
                                            elapsedTime: elapsed, usageSummary: usage,
                                            wasStoppedByUser: wasStoppedByUser ? true : nil)
                do {
                    try await flush(turn: turn, terminal: terminal)
                } catch {
                    complete = false
                    storageFailure = true
                    self.error = "Could not save the response: \(error.localizedDescription) Quit and reopen Fritz to recover the saved part."
                }
                activeMessage?.isComplete = complete
                activeMessage?.wasStoppedByUser = wasStoppedByUser
                activeMessage?.elapsedTime = elapsed
                activeMessage?.usageSummary = usage
                publishActive()
            }
            activeMessage = nil
            activeTools = []
            isResponding = false
            requestID = nil
            activity = nil
            responseTask = nil
            schedulePreferences()
            onIdle?()
        }
    }

    func stopByUser() { stop(reason: .user) }
    func stop() { stop(reason: .automatic) }

    private func stop(reason: StopReason) {
        guard let requestID, stopReason == nil else { return }
        stopReason = reason
        localModelStatus?.phase = .stopping
        agent.cancel(requestID.uuidString)
    }

    func finish() async {
        stop()
        await responseTask?.value
        _ = await savePreferences()
    }

    func clear() async {
        await finish()
        do {
            try await repository.clear(threadID)
            loadGeneration += 1
            setLatest([])
            storageFailure = false
            error = nil
            responseTokens = nil
        } catch { self.error = error.localizedDescription }
    }

    func older() async {
        guard hasOlder, let cursor = messages.first?.sequence else { return }
        await page(before: cursor)
    }

    func newer() async {
        guard hasNewer, let cursor = messages.last?.sequence else { return }
        await page(after: cursor)
    }

    func latest() async {
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let page = try await repository.transcript(threadID)
            guard generation == loadGeneration else { return }
            setLatest(page)
            publishActive()
        } catch { self.error = error.localizedDescription }
    }

    private func page(before: Int64? = nil, after: Int64? = nil) async {
        guard !isPaging else { return }
        isPaging = true
        defer { isPaging = false }
        let generation = loadGeneration
        let size = ProjectRepository.transcriptPageSize
        do {
            let page = try await repository.transcript(threadID, before: before, after: after)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            let windowSize = size * 3
            if before != nil {
                messages.insert(contentsOf: page.prefix(size).reversed(), at: 0)
                hasOlder = page.count > size
                if messages.count > windowSize {
                    messages.removeLast(messages.count - windowSize)
                    hasNewer = true
                }
            } else {
                messages.append(contentsOf: page.prefix(size))
                hasNewer = page.count > size
                trimFromStart()
            }
            publishActive()
            windowRevision += 1
        } catch { self.error = error.localizedDescription }
    }

    private func setLatest(_ page: [ChatMessage]) {
        let size = ProjectRepository.transcriptPageSize
        messages = Array(page.prefix(size).reversed())
        hasOlder = page.count > size
        hasNewer = false
        windowRevision += 1
    }

    private func trimFromStart() {
        let cap = ProjectRepository.transcriptPageSize * 3
        if messages.count > cap {
            messages.removeFirst(messages.count - cap)
            hasOlder = true
        }
    }

    private func handle(_ event: AgentEvent, data: Data, turn: UUID, model: ChatModelOption) async throws {
        switch event.type {
        case "delta":
            guard let text = event.text else { return }
            pendingText += text
            if let current = activeMessage, !current.hasMoreBody {
                let room = ProjectRepository.previewBytes - current.content.utf8.count
                let visible = ProjectRepository.prefix(text, bytes: max(room, 0))
                activeMessage?.content += visible
                activeMessage?.hasMoreBody = visible.utf8.count < text.utf8.count
                publishActive()
            }
            if pendingText.utf8.count >= ProjectRepository.bodyChunkBytes {
                try await drainScheduledFlush(turn: turn)
            } else if flushTask == nil {
                flushTask = Task {
                    do {
                        try await Task.sleep(for: .milliseconds(500))
                        if !stopRequested { try await flush(turn: turn) }
                    } catch is CancellationError {
                    } catch {
                        self.error = "Could not save the response: \(error.localizedDescription)"
                        stop()
                    }
                    flushTask = nil
                }
            }
        case "model_loading":
            localModelStatus?.loadProgress = event.progress
        case "activity":
            activity = event.message
            if event.contextTokens != nil {
                localModelStatus?.phase = .running
            }
        case "tool_start", "tool_end":
            guard let id = event.toolCallId, let name = event.name else { return }
            let current = activeTools.first { $0.id == id }
            let tool: ChatToolActivity
            if event.type == "tool_start" {
                tool = ChatToolActivity(id: id, name: name, summary: event.summary ?? name,
                                        arguments: event.historyDetails ?? event.details ?? "")
                activity = tool.summary
            } else {
                var record = try await repository.tool(turn, callID: id)
                    ?? ChatToolActivity(id: id, name: name, summary: current?.summary ?? name)
                record.result = event.historyDetails ?? event.details
                record.success = event.success
                tool = record
            }
            try await drainScheduledFlush(turn: turn, tool: tool)
            activeTools.removeAll { $0.id == id }
            activeTools.append(ChatToolActivity(id: id, name: tool.name, summary: tool.summary, success: tool.success))
            if activeTools.count > 6 { activeTools.removeFirst() }
            activeMessage?.toolCount += event.type == "tool_start" ? 1 : 0
            publishActive()
        case "usage":
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let usage = object["usage"] as? [String: Any] {
                responseUsage.append(ChatUsageCall(provider: model.provider, rawUsage: usage))
                responseTokens = Int(clamping: responseUsage.knownTokens)
            }
        default:
            break
        }
    }

    private func drainScheduledFlush(turn: UUID, tool: ChatToolActivity? = nil) async throws {
        flushTask?.cancel()
        if let flushTask { await flushTask.value }
        try await flush(turn: turn, tool: tool)
    }

    private func flush(turn: UUID, tool: ChatToolActivity? = nil, terminal: TurnMetadata? = nil) async throws {
        let text = pendingText
        pendingText = ""
        do { try await repository.checkpoint(turn: turn, text: text, tool: tool, terminal: terminal) }
        catch {
            pendingText = text + pendingText
            throw error
        }
    }

    private func publishActive() {
        if let activeMessage, let index = messages.lastIndex(where: { $0.id == activeMessage.id }) {
            messages[index] = activeMessage
        }
    }

    private var preferences: ChatPreferences {
        ChatPreferences(draft: draft, connectionID: loadedPreferences.connectionID, modelID: loadedPreferences.modelID,
                        effort: effort, speed: speed)
    }

    private func schedulePreferences() {
        guard isReady, !isStartingTurn else { return }
        preferenceTask?.cancel()
        preferenceTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(300))
                _ = await writePreferences()
            } catch {}
        }
    }

    @discardableResult func savePreferences() async -> Bool {
        preferenceTask?.cancel()
        if let preferenceTask { await preferenceTask.value }
        if isStartingTurn { return true } // The in-flight send owns this draft until commit.
        return await writePreferences()
    }

    private func writePreferences() async -> Bool {
        guard isReady, !isStartingTurn else { return true }
        let value = preferences
        guard value != savedPreferences else { return true }
        do {
            try await repository.save(preferences: value, for: threadID)
            savedPreferences = value
            return true
        } catch {
            self.error = "Could not save thread settings: \(error.localizedDescription)"
            return false
        }
    }
}

enum FritzPaths {
    static var data: URL {
        if let configured = ProcessInfo.processInfo.environment["FRITZ_DATA_DIR"]
            ?? Bundle.main.object(forInfoDictionaryKey: "FritzDataDirectory") as? String {
            return URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Fritz/Data")
    }
}
