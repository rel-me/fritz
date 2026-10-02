import AppKit
import Darwin
import Fritz
import Foundation
import Observation

/// Owns one loopback API and its resident models. Chat harnesses remain thread-owned.
@MainActor @Observable public final class ModelsLocalRuntime: ModelsRuntimeStore {
    public typealias StartPolicy = ModelsStartPolicy
    public typealias Session = ModelsRuntimeSession

    public private(set) var installedIDs: Set<String> = []
    public private(set) var sessions: [String: Session] = [:]
    public private(set) var service = Session()
    public private(set) var isLoading = false
    public var error: String?
    public private(set) var policyError: String?
    private var policies: [String: StartPolicy] = [:]
    @ObservationIgnored private let database: any ModelsPreferences
    @ObservationIgnored private var didApplyStartup = false
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private var warningAlert: NSAlert?
    @ObservationIgnored private var warningModelID: String?
    @ObservationIgnored private var pendingStarts: [String] = []
    @ObservationIgnored private let agent: AgentClient
    private let executableURL: URL?
    private let environment: [String: String]
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: Pipe?
    @ObservationIgnored private var output: Pipe?
    @ObservationIgnored private var stderr: Pipe?
    @ObservationIgnored private var pendingData = Data()
    @ObservationIgnored private var generation: UUID?

    public convenience init(agent: AgentClient, preferences: any ModelsPreferences) {
        var environment = ProcessInfo.processInfo.environment
        if let directory = Bundle.main.object(forInfoDictionaryKey: "FritzDataDirectory") as? String {
            environment["FRITZ_DATA_DIR"] = NSString(string: directory).expandingTildeInPath
        }
        if environment["FRITZ_MODELS_DIR"] == nil, let directory = Bundle.main.object(forInfoDictionaryKey: "FritzModelsDirectory") as? String {
            environment["FRITZ_MODELS_DIR"] = NSString(string: directory).expandingTildeInPath
        }
        self.init(agent: agent, preferences: preferences,
            executableURL: Bundle.main.resourceURL?.appendingPathComponent("fritz"), environment: environment)
    }
    public init(agent: AgentClient, preferences: any ModelsPreferences, executableURL: URL?, environment: [String: String]) {
        self.agent = agent
        self.executableURL = executableURL
        self.environment = environment
        self.database = preferences
        do { policies = try preferences.setting("localModelStartPolicies") ?? [:] }
        catch { policyError = "Could not restore model startup settings: \(error.localizedDescription)" }
    }

    public func policy(for modelID: String) -> StartPolicy { policies[modelID] ?? .firstUse }

    public func setPolicy(_ policy: StartPolicy, for modelID: String) throws {
        if let policyError { throw AgentFailure(message: policyError) }
        var next = policies
        next[modelID] = policy
        try database.set(next, for: "localModelStartPolicies")
        policies = next
    }

    public func startAtAppLaunch(_ connections: [ProviderConnection]) async {
        startService()
        guard !didApplyStartup, !isShuttingDown, policyError == nil else { return }
        await refresh()
        guard !Task.isCancelled, !isShuttingDown, !didApplyStartup, error == nil else { return }
        didApplyStartup = true
        for connection in connections where connection.provider == .fritz && policy(for: connection.modelID) == .appStart {
            start(connection.modelID)
        }
    }

    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let inventory: Inventory = try await agent.request("localModels.list")
            installedIDs = Set(inventory.models.filter(\.installed).map(\.id))
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    public func start(_ modelID: String) {
        guard !isShuttingDown else { return }
        guard installedIDs.contains(modelID) else {
            sessions[modelID] = Session(status: .failed, error: "Model is not installed.")
            command("deny", modelID)
            return
        }
        if sessions[modelID]?.status == .stopping { command("deny", modelID); return }
        guard sessions[modelID]?.status != .running, sessions[modelID]?.status != .starting,
              warningModelID != modelID, !pendingStarts.contains(modelID) else { return }
        pendingStarts.append(modelID)
        startNext()
    }

    private func startNext() {
        guard !isShuttingDown, warningAlert == nil, !pendingStarts.isEmpty else { return }
        let modelID = pendingStarts.removeFirst()
        let catalog = NativeModelDescriptor.catalog
        if let model = catalog.first(where: { $0.id == modelID }),
           let warning = Self.memoryWarning(model: model, activeModels: catalog.filter {
               sessions[$0.id]?.status == .running || sessions[$0.id]?.status == .starting || sessions[$0.id]?.status == .stopping
           }, memoryGB: LocalModelHardware.current.memoryGB, availableGB: Self.availableMemoryGB) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Limited memory"
            alert.informativeText = warning
            alert.addButton(withTitle: "Start Anyway")
            alert.addButton(withTitle: "Cancel")
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
                sessions[modelID] = Session(status: .failed, error: warning)
                command("deny", modelID)
                startNext()
                return
            }
            warningAlert = alert
            warningModelID = modelID
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                warningAlert = nil
                warningModelID = nil
                if response == .alertFirstButtonReturn, !isShuttingDown { load(modelID) }
                else { command("deny", modelID) }
                startNext()
            }
        } else {
            load(modelID)
            startNext()
        }
    }

    private func load(_ modelID: String) {
        guard !isShuttingDown else { return }
        startService()
        if command("start", modelID) {
            sessions[modelID] = Session(status: .starting, processID: service.processID)
        } else {
            sessions[modelID] = Session(status: .failed, error: service.error ?? "Local API is unavailable.")
        }
    }

    public static func memoryWarning(model: NativeModelDescriptor, activeModels: [NativeModelDescriptor],
                              memoryGB: Int, availableGB: Int?) -> String? {
        guard !activeModels.isEmpty else { return nil }
        let estimate = activeModels.reduce(model.memoryGB) { $0 + $1.memoryGB }
        guard estimate > memoryGB || (availableGB.map { model.memoryGB > $0 } ?? true) else { return nil }
        let available = availableGB.map { "About \($0) GB is available." } ?? "Available RAM could not be measured."
        return "Running these models is estimated to need \(estimate) GB RAM. This Mac has \(memoryGB) GB. \(available)"
    }

    private static var availableMemoryGB: Int? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.speculative_count)
        return max(0, Int(pages * UInt64(pageSize) / 1_073_741_824) - 2)
    }

    public func startService() {
        guard !isShuttingDown, process == nil else { return }
        guard let executable = executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            service = Session(status: .failed, error: "The bundled fritz executable is missing.")
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["local-models", "serve", "--port", "0", "--managed"]
        process.environment = environment
        let input = Pipe(), output = Pipe(), stderr = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = stderr
        let generation = UUID()
        self.generation = generation
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { return }
            Task { @MainActor [weak self] in self?.receive(bytes, generation: generation) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { return }
            let message = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation, service.status == .starting else { return }
                service.error = message
            }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in self?.terminated(generation: generation, status: process.terminationStatus) }
        }
        do {
            try process.run()
            self.process = process
            self.input = input
            self.output = output
            self.stderr = stderr
            service = Session(status: .starting, processID: process.processIdentifier)
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            self.generation = nil
            service = Session(status: .failed, error: error.localizedDescription)
        }
    }

    @discardableResult private func command(_ action: String, _ modelID: String) -> Bool {
        guard let input, process?.isRunning == true else { return false }
        do {
            var data = try JSONSerialization.data(withJSONObject: ["action": action, "modelId": modelID])
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
            return true
        } catch {
            service.error = "Could not control the local API: \(error.localizedDescription)"
            return false
        }
    }

    public func stop(_ modelID: String) {
        pendingStarts.removeAll { $0 == modelID }
        if warningModelID == modelID, let window = warningAlert?.window, let parent = window.sheetParent {
            parent.endSheet(window, returnCode: .alertSecondButtonReturn)
        }
        if command("stop", modelID) {
            sessions[modelID] = Session(status: .stopping, processID: service.processID)
        } else { sessions[modelID] = Session() }
    }

    public func stopAll() {
        isShuttingDown = true
        if let window = warningAlert?.window, let parent = window.sheetParent {
            parent.endSheet(window, returnCode: .alertSecondButtonReturn)
        }
        pendingStarts = []
        disposeService()
        sessions = [:]
        service = Session()
    }

    private func disposeService() {
        generation = nil
        output?.fileHandleForReading.readabilityHandler = nil
        stderr?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        input = nil; output = nil; stderr = nil; pendingData = Data()
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    private func receive(_ bytes: Data, generation: UUID) {
        guard self.generation == generation else { return }
        pendingData.append(bytes)
        while let newline = pendingData.firstIndex(of: 10) {
            let line = pendingData[..<newline]
            let event = try? JSONDecoder().decode(ServiceEvent.self, from: Data(line))
            pendingData.removeSubrange(...newline)
            guard let event else { continue }
            switch event.type {
            case "service":
                service = Session(status: .running, processID: process?.processIdentifier, address: event.address)
            case "model":
                guard let id = event.modelId, let status = event.status else { continue }
                let state: Session.Status
                switch status {
                case "starting": state = .starting
                case "running": state = .running
                case "stopped": state = .stopped
                default: state = .failed
                }
                if sessions[id]?.status == .stopping, state != .stopped { continue }
                sessions[id] = Session(status: state, processID: state == .stopped ? nil : service.processID,
                                       error: event.error)
            case "loadRequested":
                guard let id = event.modelId else { continue }
                // The service verifies catalog membership and file presence before admission.
                installedIDs.insert(id)
                start(id)
            default: break
            }
        }
    }

    private func terminated(generation: UUID, status: Int32) {
        guard self.generation == generation else { return }
        let failure = service.error ?? "Local API exited with status \(status)."
        disposeService()
        service = Session(status: .failed, error: failure)
        pendingStarts = []
        if let window = warningAlert?.window, let parent = window.sheetParent {
            parent.endSheet(window, returnCode: .alertSecondButtonReturn)
        }
        for id in sessions.keys { sessions[id] = Session(status: .failed, error: failure) }
    }
}

private struct ServiceEvent: Decodable {
    let type: String
    var modelId: String?
    var status: String?
    var address: String?
    public var error: String?
}

private struct Inventory: Decodable {
    struct Model: Decodable { let id: String; let installed: Bool }
    let models: [Model]
}
