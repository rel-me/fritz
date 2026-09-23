import Foundation
import Observation

struct AgentFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct AgentEvent: Decodable, Sendable {
    let id: String
    let type: String
    let text: String?
    let message: String?
    let toolCallId: String?
    let name: String?
    let summary: String?
    let details: String?
    let success: Bool?
}

/// One app-owned process. Private pipes carry requests and credentials; stdout is protocol only.
@MainActor @Observable final class AgentClient {
    private(set) var isRunning = false
    private(set) var startupError: String?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var pending: [String: AsyncThrowingStream<Data, Error>.Continuation] = [:]
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    func start() {
        guard process == nil else { return }
        let process = Process()
        let executable = Bundle.main.resourceURL?.appendingPathComponent("fritz")
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            startupError = "The bundled fritz agent is missing. Build the app with make build."
            return
        }
        process.executableURL = executable
        process.arguments = ["--agent"]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "FRITZ_KEYCHAIN_SERVICE")
        if let dataDirectory = Bundle.main.object(forInfoDictionaryKey: "FritzDataDirectory") as? String {
            environment["FRITZ_DATA_DIR"] = NSString(string: dataDirectory).expandingTildeInPath
        }
        if let service = Bundle.main.object(forInfoDictionaryKey: "FritzKeychainService") as? String,
           !service.isEmpty {
            environment["FRITZ_KEYCHAIN_SERVICE"] = service
        }
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            self.process = process
            self.input = stdin.fileHandleForWriting
            self.isRunning = true
            self.startupError = nil
            let token = UUID()
            generation = token
            let handle = stdout.fileHandleForReading
            reader = Task.detached { [weak self] in
                var buffer = Data()
                while !Task.isCancelled {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    buffer.append(data)
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<newline])
                        buffer.removeSubrange(...newline)
                        await self?.receive(line, generation: token)
                    }
                }
                await self?.disconnected(generation: token)
            }
        } catch { startupError = error.localizedDescription }
    }

    func stop() {
        generation = UUID()
        reader?.cancel()
        try? input?.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        isRunning = false
        finishPending("The Fritz agent stopped.")
    }

    func restart() { stop(); start() }

    func stream(method: String, params: [String: Any] = [:], id: String = UUID().uuidString) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            guard isRunning, let input else {
                continuation.finish(throwing: AgentFailure(message: startupError ?? "The Fritz agent is not running.")); return
            }
            do {
                var data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
                data.append(10)
                pending[id] = continuation
                try input.write(contentsOf: data)
            } catch {
                pending.removeValue(forKey: id)
                continuation.finish(throwing: error)
            }
        }
    }

    func request<T: Decodable>(_ method: String, params: [String: Any] = [:], as: T.Type = T.self) async throws -> T {
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            for try await data in stream(method: method, params: params, id: id) {
                try Task.checkCancellation()
                let event = try JSONDecoder().decode(AgentEvent.self, from: data)
                if event.type == "result",
                   let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let result = object["result"] {
                    return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: result))
                }
            }
            throw AgentFailure(message: "The agent returned no result.")
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    func cancel(_ id: String) {
        // Immediately detach this consumer, then cancel the network request in Rust.
        pending.removeValue(forKey: id)?.finish(throwing: CancellationError())
        guard let input else { return }
        if var data = try? JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "method": "cancel", "params": ["requestId": id]]) {
            data.append(10); try? input.write(contentsOf: data)
        }
    }

    private func receive(_ data: Data, generation: UUID) {
        guard generation == self.generation,
              let event = try? JSONDecoder().decode(AgentEvent.self, from: data),
              let continuation = pending[event.id] else { return }
        if event.type == "error" {
            pending.removeValue(forKey: event.id)
            continuation.finish(throwing: AgentFailure(message: event.message ?? "The agent request failed."))
        } else if event.type == "cancelled" {
            pending.removeValue(forKey: event.id)?.finish(throwing: CancellationError())
        } else {
            continuation.yield(data)
            if event.type == "result" { pending.removeValue(forKey: event.id)?.finish() }
        }
    }

    private func disconnected(generation: UUID) {
        guard generation == self.generation else { return }
        process = nil; input = nil; isRunning = false
        startupError = "The Fritz agent disconnected. Restart it to continue."
        finishPending(startupError!)
    }
    private func finishPending(_ message: String) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.finish(throwing: AgentFailure(message: message)) }
    }
}

extension Encodable {
    func jsonObject() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
    }
}
