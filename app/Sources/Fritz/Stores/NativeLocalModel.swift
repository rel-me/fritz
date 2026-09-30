import Fritz
import Foundation
import Observation

/// Downloads share the app's private agent transport and are cancelled with the sheet.
@MainActor @Observable final class NativeLocalModel {
    static let defaultModelID = "qwen2.5-1.5b-instruct-q4_k_m"
    var category: AIModelCategory { selectedModel.category }
    let catalog: [NativeModelDescriptor]
    private(set) var selectedModelID: String
    private(set) var state: NativeModelInstallState = .available
    private(set) var installedURL: URL?
    var selectedModel: NativeModelDescriptor {
        catalog.first { $0.id == selectedModelID }!
    }
    @ObservationIgnored private let agent: AgentClient
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requestID: String?

    init(agent: AgentClient, modelID: String? = nil, category: AIModelCategory? = nil) {
        catalog = (NativeModelDescriptor.catalog + NativeModelDescriptor.decisionCatalog)
            .filter { category == nil || $0.category == category }
        self.agent = agent
        selectedModelID = catalog.first { $0.id == modelID }?.id ?? (category == .decision ? catalog[0].id : Self.defaultModelID)
    }

    func select(_ id: String) {
        guard id != selectedModelID, catalog.contains(where: { $0.id == id }) else { return }
        cancel()
        selectedModelID = id
        refresh()
    }
    func refresh() { run(install: false) }
    func install() { run(install: true) }

    func cancel() {
        if let requestID { agent.cancel(requestID) }
        requestID = nil
        task?.cancel(); task = nil
        if state.isBusy { state = .available }
    }

    private func run(install: Bool) {
        cancel()
        state = .checking
        installedURL = nil
        let id = UUID().uuidString
        let modelID = selectedModelID
        requestID = id
        let prefix = category == .decision ? "decisionModels" : "localModels"
        let events = agent.stream(method: "\(prefix).\(install ? "install" : "list")",
                                  params: ["modelId": modelID], id: id)
        task = Task { [weak self] in
            var completed = false
            do {
                for try await data in events {
                    guard let self, requestID == id, !Task.isCancelled else { return }
                    let event = try JSONDecoder().decode(LocalModelEvent.self, from: data)
                    state = try event.state(for: modelID, installing: install)
                    if let model = event.result?.models?.first(where: { $0.id == modelID }),
                       model.installed, let path = model.path {
                        installedURL = URL(fileURLWithPath: path)
                    }
                    if event.type == "result" { completed = true }
                }
                guard let self, requestID == id, !Task.isCancelled else { return }
                if !completed { state = .failed("The model installer stopped before completing. Retry the download.") }
            } catch is CancellationError {
            } catch {
                guard let self, requestID == id, !Task.isCancelled else { return }
                agent.cancel(id)
                state = .failed(error.localizedDescription)
            }
            guard let self, requestID == id else { return }
            requestID = nil; task = nil
        }
    }
}

struct LocalModelEvent: Decodable {
    struct InventoryModel: Decodable { let id: String; let installed: Bool; let path: String? }
    struct Result: Decodable {
        let models: [InventoryModel]?
        let modelId: String?
        let installed: Bool?
    }
    let type: String
    let status: String?
    let downloaded: UInt64?
    let total: UInt64?
    let result: Result?

    func state(for modelID: String, installing: Bool) throws -> NativeModelInstallState {
        if type == "result", let result {
            if installing, result.modelId == modelID, result.installed == true { return .installed }
            if !installing, let model = result.models?.first(where: { $0.id == modelID }) {
                return model.installed ? .installed : .available
            }
        }
        if installing, type == "progress", let downloaded, let total,
           total > 0, total <= UInt64(Int64.max), downloaded <= total {
            switch status {
            case "checking": return .checking
            case "downloading": return .downloading(downloaded: downloaded, total: total)
            case "ready" where downloaded == total: return .checking // Await the terminal result before saving.
            default: break
            }
        }
        throw AgentFailure(message: "Fritz’s model installer returned invalid progress. Retry the download.")
    }
}
