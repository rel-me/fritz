import Foundation
import Observation

/// Owns only API processes launched by this Fritz instance. Chat harnesses stay
/// owned by their threads and are not affected by these controls.
@MainActor @Observable final class LocalModelRuntimeStore {
    struct Session {
        enum Status { case stopped, starting, running, failed }
        var status: Status = .stopped
        var processID: Int32?
        var address: String?
        var error: String?
    }

    private(set) var installedIDs: Set<String> = []
    private(set) var sessions: [String: Session] = [:]
    private(set) var isLoading = false
    var error: String?
    @ObservationIgnored private let agent: AgentClient
    @ObservationIgnored private var processes: [String: Process] = [:]
    @ObservationIgnored private var stderrPipes: [String: Pipe] = [:]
    @ObservationIgnored private var pendingData: [String: Data] = [:]
    @ObservationIgnored private var generations: [String: UUID] = [:]

    init(agent: AgentClient) { self.agent = agent }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let inventory: Inventory = try await agent.request("localModels.list")
            installedIDs = Set(inventory.models.filter(\.installed).map(\.id))
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func start(_ modelID: String) {
        guard installedIDs.contains(modelID), processes[modelID] == nil else { return }
        guard let executable = Bundle.main.resourceURL?.appendingPathComponent("fritz"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            sessions[modelID] = Session(status: .failed, error: "The bundled fritz executable is missing.")
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["local-models", "serve", "--port", "0", "--model", modelID]
        var environment = ProcessInfo.processInfo.environment
        if let dataDirectory = Bundle.main.object(forInfoDictionaryKey: "FritzDataDirectory") as? String {
            environment["FRITZ_DATA_DIR"] = NSString(string: dataDirectory).expandingTildeInPath
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        let generation = UUID()
        generations[modelID] = generation
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { return }
            Task { @MainActor [weak self] in self?.receive(bytes, modelID: modelID, generation: generation) }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in self?.terminated(modelID, generation: generation, status: process.terminationStatus) }
        }
        do {
            try process.run()
            processes[modelID] = process
            stderrPipes[modelID] = stderr
            sessions[modelID] = Session(status: .starting, processID: process.processIdentifier)
        } catch {
            stderr.fileHandleForReading.readabilityHandler = nil
            generations[modelID] = nil
            sessions[modelID] = Session(status: .failed, error: error.localizedDescription)
        }
    }

    func stop(_ modelID: String) {
        generations[modelID] = nil
        stderrPipes[modelID]?.fileHandleForReading.readabilityHandler = nil
        stderrPipes[modelID] = nil
        pendingData[modelID] = nil
        if let process = processes.removeValue(forKey: modelID), process.isRunning { process.terminate() }
        sessions[modelID] = Session()
    }

    func restart(_ modelID: String) { stop(modelID); start(modelID) }

    func stopAll() {
        for id in Array(processes.keys) { stop(id) }
    }

    private func receive(_ bytes: Data, modelID: String, generation: UUID) {
        guard generations[modelID] == generation else { return }
        var pending = pendingData[modelID] ?? Data()
        pending.append(bytes)
        while let newline = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<newline], as: UTF8.self)
            pending.removeSubrange(...newline)
            receiveLine(line, modelID: modelID)
        }
        pendingData[modelID] = pending
    }

    private func receiveLine(_ line: String, modelID: String) {
        if let range = line.range(of: "http://127.0.0.1:"),
           let address = line[range.lowerBound...].split(whereSeparator: \.isWhitespace).first {
            sessions[modelID] = Session(status: .running, processID: processes[modelID]?.processIdentifier,
                                        address: String(address))
        } else if sessions[modelID]?.status == .starting {
            sessions[modelID]?.error = line
        }
    }

    private func terminated(_ modelID: String, generation: UUID, status: Int32) {
        guard generations[modelID] == generation else { return }
        let failure = sessions[modelID]?.error ?? "Local model API exited with status \(status)."
        stop(modelID)
        sessions[modelID] = Session(status: .failed, error: failure)
    }
}

private struct Inventory: Decodable {
    struct Model: Decodable { let id: String; let installed: Bool }
    let models: [Model]
}
