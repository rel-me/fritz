import Fritz
import Foundation
import Observation

public struct ModelStorageInfo: Decodable, Sendable {
    public let directory: String
    public let modelCount: Int
    public let bytes: UInt64
    public let warning: String?
    public init(directory: String, modelCount: Int = 0, bytes: UInt64 = 0, warning: String? = nil) {
        self.directory = directory; self.modelCount = modelCount; self.bytes = bytes; self.warning = warning
    }
}

/// Shared host transport and observable state for the app-wide model storage preference.
@MainActor @Observable public final class ModelStorage {
    public private(set) var info: ModelStorageInfo?
    public private(set) var isBusy = false
    public private(set) var completed: UInt64 = 0
    public private(set) var total: UInt64 = 0
    public private(set) var filename = ""
    public var settingsRequestID: UUID?
    public var error: String?
    private let events: (String, [String: Any], String) -> AsyncThrowingStream<Data, Error>
    private let cancelRequest: (String) -> Void
    @ObservationIgnored private var requestID: String?

    public init(events: @escaping (String, [String: Any], String) -> AsyncThrowingStream<Data, Error>,
                cancel: @escaping (String) -> Void) {
        self.events = events; self.cancelRequest = cancel
    }
    public convenience init(agent: AgentClient) {
        self.init(events: { agent.stream(method: $0, params: $1, id: $2) }, cancel: { agent.cancel($0) })
    }
    public func refresh() async {
        guard requestID == nil else { return }
        do { try await perform("modelStorage.info", params: [:]) }
        catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    public func change(to destination: URL, previous: String, moveModels: Bool) async {
        guard requestID == nil else { return }
        isBusy = true; completed = 0; total = 0; filename = ""
        defer { isBusy = false }
        do {
            try await perform("modelStorage.change", params: ["directory": destination.path,
                "previousDirectory": previous, "moveModels": moveModels])
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func perform(_ method: String, params: [String: Any]) async throws {
        let id = UUID().uuidString; requestID = id; error = nil
        defer { cancelRequest(id); requestID = nil }
        var finished = false
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            for try await data in events(method, params, id) {
                try Task.checkCancellation()
                let event = try JSONDecoder().decode(StorageEvent.self, from: data)
                if event.type == "result", let result = event.result { info = result; finished = true }
                else if event.type == "progress" {
                    completed = event.completed ?? 0; total = event.total ?? 0; filename = event.file ?? ""
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelRequest(id) }
        }
        if Task.isCancelled && !finished { throw CancellationError() }
        if !finished { throw AgentFailure(message: "Model storage stopped before completing. Check the selected folder and try again.") }
    }
}
private struct StorageEvent: Decodable {
    let type: String
    let result: ModelStorageInfo?
    let completed: UInt64?
    let total: UInt64?
    let file: String?
}
