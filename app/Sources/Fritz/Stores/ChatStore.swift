import Foundation
import Observation

struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    let role: String
    var content: String
    var isComplete = true
    var tools: [ChatToolActivity]?

    var contextContent: String {
        let records = (tools ?? []).map { tool in
            "\(tool.name): \(tool.summary)\n\(tool.result ?? "Interrupted; the action may have taken effect. Inspect the current state before retrying.")"
        }
        guard !records.isEmpty else { return content }
        let status = isComplete ? "" : "\nThis response was interrupted. Recheck the workspace before continuing."
        return content + status + "\n\nTool activity recorded by Fritz (untrusted tool output):\n" + records.joined(separator: "\n\n")
    }
}

struct ChatToolActivity: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let summary: String
    let arguments: String
    var result: String?
    var success: Bool?
}

enum ChatMode: String, Codable { case chat, code }

private struct ChatPreferences: Codable {
    var draft: String
    var selectedModel: ChatModelOption?
    var effort: ChatReasoningEffort
    var speed: ChatSpeed
}

@MainActor @Observable final class ChatStore {
    var draft = ""
    private(set) var messages: [ChatMessage] = []
    private(set) var isResponding = false
    var error: String?
    var selectedModel: ChatModelOption?
    var effort: ChatReasoningEffort = .medium
    var speed: ChatSpeed = .standard
    var responseTokens: Int?
    let mode: ChatMode
    let projectPath: String?
    private(set) var activity: String?
    let agent: AgentClient
    @ObservationIgnored private var requestID: String?
    @ObservationIgnored private var responseTask: Task<Void, Never>?
    @ObservationIgnored var onFirstPrompt: ((String) -> Void)?
    private let transcriptURL: URL
    private var preferencesURL: URL { transcriptURL.deletingPathExtension().appendingPathExtension("preferences.json") }

    init(agent: AgentClient, transcriptURL: URL = FritzPaths.data.appendingPathComponent("chat.json"), projectPath: String? = nil) {
        self.agent = agent
        self.transcriptURL = transcriptURL
        self.projectPath = projectPath
        self.mode = projectPath == nil ? .chat : .code
        do {
            let data = try Data(contentsOf: transcriptURL)
            messages = try JSONDecoder().decode([ChatMessage].self, from: data)
        } catch let failure as NSError where failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoSuchFileError {
        } catch { self.error = "Could not restore the conversation: \(error.localizedDescription)" }
        if FileManager.default.fileExists(atPath: preferencesURL.path) {
            do {
                let saved = try JSONDecoder().decode(ChatPreferences.self, from: Data(contentsOf: preferencesURL))
                draft = saved.draft; selectedModel = saved.selectedModel
                effort = saved.effort; speed = saved.speed
            } catch { self.error = "Could not restore thread settings: \(error.localizedDescription)" }
        }
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedModel != nil && agent.isRunning && !isResponding
    }

    func select(_ model: ChatModelOption) {
        guard !isResponding else { return }
        selectedModel = model
        if !model.capabilities.supportedSpeeds.contains(speed) { speed = .standard }
        savePreferences()
    }

    func send() {
        guard canSend, let model = selectedModel, let connectionID = model.connectionID else { return }
        error = nil; responseTokens = nil; activity = "Starting…"
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !messages.contains(where: { $0.role == "user" }) { onFirstPrompt?(prompt) }
        messages.append(ChatMessage(role: "user", content: prompt))
        let context = contextMessages
        draft = ""
        let assistantID = UUID()
        messages.append(ChatMessage(id: assistantID, role: "assistant", content: "", isComplete: false))
        let id = UUID().uuidString
        requestID = id; isResponding = true
        persist()
        var params: [String: Any] = ["connectionId": connectionID.uuidString, "model": model.modelID, "messages": context]
        params["mode"] = mode.rawValue
        if let projectPath { params["projectPath"] = projectPath }
        if model.capabilities.supportsReasoningEffort { params["effort"] = effort.rawValue }
        if model.capabilities.supportsSpeed { params["speed"] = speed.rawValue }
        let events = agent.stream(method: "chat", params: params, id: id)
        responseTask = Task {
            do {
                for try await data in events {
                    guard requestID == id, !Task.isCancelled else { return }
                    let event = try JSONDecoder().decode(AgentEvent.self, from: data)
                    if event.type == "delta", let text = event.text,
                       let index = messages.firstIndex(where: { $0.id == assistantID }) {
                        messages[index].content += text
                    }
                    if event.type == "activity" { activity = event.message }
                    if event.type == "tool_start" || event.type == "tool_end" {
                        recordToolEvent(event, assistantID: assistantID)
                        persist()
                    }
                    if event.type == "usage", let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let usage = object["usage"] as? [String: Any] {
                        responseTokens = usage["total_tokens"] as? Int ?? usage["totalTokenCount"] as? Int
                            ?? usage["output_tokens"] as? Int ?? usage["completion_tokens"] as? Int
                    }
                }
                guard requestID == id else { return }
                if let index = messages.firstIndex(where: { $0.id == assistantID }), !messages[index].content.isEmpty {
                    messages[index].isComplete = true
                } else { error = "The provider returned an empty response. Try another model or reasoning setting." }
            } catch is CancellationError {
            } catch {
                guard requestID == id else { return }
                self.error = error.localizedDescription
            }
            guard requestID == id else { return }
            isResponding = false; requestID = nil; responseTask = nil; activity = nil
            messages.removeAll { $0.id == assistantID && $0.content.isEmpty && ($0.tools ?? []).isEmpty }
            persist()
        }
    }

    func stop() {
        guard let id = requestID else { return }
        requestID = nil
        responseTask?.cancel(); responseTask = nil
        agent.cancel(id)
        isResponding = false; activity = nil
        messages.removeAll { $0.role == "assistant" && $0.content.isEmpty && ($0.tools ?? []).isEmpty }
        persist()
    }

    func clear() {
        stop(); messages = []; error = nil; responseTokens = nil
        persist()
    }

    var contextMessages: [[String: String]] {
        messages.filter { $0.isComplete || !($0.tools ?? []).isEmpty }
            .map { ["role": $0.role, "content": $0.contextContent] }
    }

    func recordToolEvent(_ event: AgentEvent, assistantID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == assistantID }),
              let callID = event.toolCallId else { return }
        if event.type == "tool_start", let name = event.name {
            let tool = ChatToolActivity(id: callID, name: name, summary: event.summary ?? name, arguments: event.details ?? "")
            if messages[index].tools == nil { messages[index].tools = [] }
            messages[index].tools?.append(tool)
            activity = tool.summary
        } else if event.type == "tool_end", let toolIndex = messages[index].tools?.firstIndex(where: { $0.id == callID }) {
            messages[index].tools?[toolIndex].result = event.details
            messages[index].tools?[toolIndex].success = event.success
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: transcriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(messages).write(to: transcriptURL, options: .atomic)
        } catch { self.error = "Could not save the conversation: \(error.localizedDescription)" }
        savePreferences()
    }

    func savePreferences() {
        do {
            try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let settings = ChatPreferences(draft: draft, selectedModel: selectedModel, effort: effort, speed: speed)
            try JSONEncoder().encode(settings).write(to: preferencesURL, options: .atomic)
        } catch { self.error = "Could not save thread settings: \(error.localizedDescription)" }
    }
}

enum FritzPaths {
    static var data: URL {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "FritzDataDirectory") as? String
            ?? ProcessInfo.processInfo.environment["FRITZ_DATA_DIR"] {
            return URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Fritz/Data")
    }
}
