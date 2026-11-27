import Foundation
import Observation

@MainActor @Observable
final class ChatStore {
    private(set) var workspace = Workspace()
    private(set) var activeChatID: UUID?
    private(set) var storageIssue: String?
    var notice: String?

    @ObservationIgnored private var file: WorkspaceFile?
    @ObservationIgnored private var replyTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init() { load() }

    func load() {
        do {
            let file = try WorkspaceFile()
            var state = try file.read()
            for chat in state.conversations.indices {
                for message in state.conversations[chat].messages.indices
                where state.conversations[chat].messages[message].status == .streaming {
                    state.conversations[chat].messages[message].status = .stopped
                }
            }
            workspace = state
            self.file = file
            storageIssue = nil
        } catch {
            storageIssue = "Fritz could not open the saved workspace. \(error.localizedDescription)"
        }
    }

    func select(_ id: UUID?) {
        workspace.selectedID = id
        scheduleSave()
    }

    func newChat() -> UUID? {
        let chat = Conversation()
        var state = workspace
        state.conversations.insert(chat, at: 0)
        state.selectedID = chat.id
        do {
            try commit(state)
            return chat.id
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    func deleteChat(_ id: UUID) {
        var state = workspace
        state.conversations.removeAll { $0.id == id }
        if state.selectedID == id { state.selectedID = nil }
        do {
            try commit(state)
            if activeChatID == id {
                replyTask?.cancel()
                replyTask = nil
                activeChatID = nil
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    func updateDraft(_ draft: String, chatID: UUID) {
        guard let index = chatIndex(chatID) else { return }
        workspace.conversations[index].draft = draft
        scheduleSave()
    }

    func setModel(provider: UUID, model: String, chatID: UUID) throws {
        guard activeChatID != chatID, let index = chatIndex(chatID),
              workspace.providers.contains(where: { $0.id == provider }) else {
            throw ChatFailure("The chat or provider is unavailable.")
        }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw ChatFailure("Enter a model ID or choose a discovered model.") }
        var state = workspace
        state.conversations[index].providerID = provider
        state.conversations[index].model = model
        try commit(state)
    }

    func key(for connection: ProviderConnection, replacement: String) throws -> Data? {
        let text = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return Data(text.utf8) }
        let saved = workspace.providers.first { $0.id == connection.id }
        let unchanged = saved?.kind == connection.kind && saved?.endpoint == connection.endpoint
        return try ProviderKeychain.read(unchanged ? saved?.credentialID : nil)
    }

    func saveProvider(_ edit: ProviderConnection, replacement: String) throws {
        let previous = workspace.providers.first { $0.id == edit.id }
        var connection = edit
        connection.name = edit.name.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.customEndpoint = edit.customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if connection.name.isEmpty { connection.name = connection.kind.title }
        let replacesKey = !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let key = try key(for: connection, replacement: replacement)
        try connection.validate(key: key)
        let newID = replacesKey ? UUID() : nil
        connection.credentialID = newID ?? (key == nil ? nil : previous?.credentialID)

        if let newID, let key { try ProviderKeychain.insert(key, id: newID) }
        var state = workspace
        if let index = state.providers.firstIndex(where: { $0.id == connection.id }) {
            if previous?.kind != connection.kind || previous?.endpoint != connection.endpoint {
                for chat in state.conversations.indices where state.conversations[chat].providerID == connection.id {
                    state.conversations[chat].providerID = nil
                    state.conversations[chat].model = ""
                }
            }
            state.providers[index] = connection
        } else {
            state.providers.append(connection)
        }
        do {
            try commit(state)
        } catch {
            do { try ProviderKeychain.remove(newID) } catch { notice = error.localizedDescription }
            throw error
        }
        if previous?.credentialID != connection.credentialID {
            do { try ProviderKeychain.remove(previous?.credentialID) } catch { notice = error.localizedDescription }
        }
    }

    func deleteProvider(_ id: UUID) {
        guard let provider = workspace.providers.first(where: { $0.id == id }) else { return }
        var state = workspace
        state.providers.removeAll { $0.id == id }
        do {
            try commit(state)
            try ProviderKeychain.remove(provider.credentialID)
        } catch {
            notice = error.localizedDescription
        }
    }

    func send(_ chatID: UUID, retry: Bool = false) {
        guard activeChatID == nil, let index = chatIndex(chatID) else { return }
        var chat = workspace.conversations[index]
        guard let connection = workspace.providers.first(where: { $0.id == chat.providerID }),
              !chat.model.isEmpty else {
            notice = "Choose a provider and model before sending."
            return
        }
        do {
            let key = try ProviderKeychain.read(connection.credentialID)
            try connection.validate(key: key)
            if retry {
                guard let last = chat.messages.last, last.role == .assistant,
                      last.status == .failed || last.status == .stopped else { return }
                chat.messages.removeLast()
            } else {
                let prompt = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !prompt.isEmpty else { return }
                if chat.messages.isEmpty {
                    chat.title = String(prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(52))
                }
                chat.messages.append(ChatMessage(role: .user, content: prompt))
                chat.draft = ""
            }
            let request = ProviderRuntime.Request(connection, model: chat.model, messages: chat.messages.filter { $0.status == nil })
            let reply = ChatMessage(role: .assistant, content: "", status: .streaming)
            chat.messages.append(reply)
            var state = workspace
            state.conversations[index] = chat
            try commit(state)

            activeChatID = chatID
            replyTask = Task { [weak self] in
                var checkpoint = ContinuousClock.now
                do {
                    for try await event in ProviderRuntime.events(request, key: key) {
                        try Task.checkCancellation()
                        if let text = event.text {
                            guard let self, let index = self.chatIndex(chatID),
                                  self.workspace.conversations[index].messages.last?.id == reply.id else { return }
                            let messageIndex = self.workspace.conversations[index].messages.count - 1
                            self.workspace.conversations[index].messages[messageIndex].content += text
                            if checkpoint.duration(to: .now) >= .seconds(1) {
                                self.flush()
                                checkpoint = .now
                            }
                        }
                    }
                    try Task.checkCancellation()
                    self?.finish(chatID, message: reply.id, status: nil)
                } catch is CancellationError {
                    self?.finish(chatID, message: reply.id, status: .stopped)
                } catch {
                    self?.finish(chatID, message: reply.id, status: .failed, error: error.localizedDescription)
                }
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    func stop() { replyTask?.cancel() }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard let file else { return }
        do { try file.write(workspace) } catch { notice = error.localizedDescription }
    }

    private func finish(_ chatID: UUID, message: UUID, status: ChatMessage.Status?, error: String? = nil) {
        guard activeChatID == chatID, let index = chatIndex(chatID),
              let last = workspace.conversations[index].messages.last, last.id == message else { return }
        let messageIndex = workspace.conversations[index].messages.count - 1
        let emptyReply = status == nil && last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        workspace.conversations[index].messages[messageIndex].status = emptyReply ? .failed : status
        activeChatID = nil
        replyTask = nil
        if let error { notice = error }
        if emptyReply { notice = "The provider finished without returning a text reply." }
        flush()
    }

    private func chatIndex(_ id: UUID) -> Int? {
        workspace.conversations.firstIndex { $0.id == id }
    }

    private func commit(_ state: Workspace) throws {
        guard let file else { throw ChatFailure("The workspace is unavailable.") }
        try file.write(state)
        saveTask?.cancel()
        saveTask = nil
        workspace = state
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                self?.flush()
            } catch is CancellationError {
                return
            } catch {
                self?.notice = error.localizedDescription
            }
        }
    }
}
