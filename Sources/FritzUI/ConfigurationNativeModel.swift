import Fritz
import Foundation
import Observation

/// App-owned transfers are shared by every view of the model.
@MainActor @Observable public final class ModelDownloads {
    private var transfers: [String: ModelTransfer] = [:]
    private(set) var completedDownloads = 0

    public init() {}

    subscript(modelID: String) -> ModelTransfer? { transfers[modelID] }

    fileprivate func transfer(for model: NativeModelDescriptor, store: any ModelsProviderStore) -> ModelTransfer {
        if let transfer = transfers[model.id] { return transfer }
        let transfer = ModelTransfer(model: model, store: store) { [weak self] in
            self?.completedDownloads += 1
        }
        transfers[model.id] = transfer
        return transfer
    }
}

@MainActor @Observable final class ConfigurationNativeModel<Store: ModelsProviderStore> {
    static var defaultModelID: String { "qwen2.5-1.5b-instruct-q4_k_m" }
    var category: AIModelCategory { selectedModel.category }
    let catalog: [NativeModelDescriptor]
    private(set) var selectedModelID: String
    var state: LocalModelInstallState { transfer?.state ?? .available }
    var isDownloading: Bool { transfer?.isDownloading ?? false }
    var installedURL: URL? { transfer?.installedURL }
    var downloadDirectory: URL? { transfer?.downloadDirectory }
    var completedDownloadID: String? { transfer?.completedDownloadID }
    var selectedModel: NativeModelDescriptor {
        catalog.first { $0.id == selectedModelID }!
    }
    private var transfer: ModelTransfer? { store.modelDownloads[selectedModelID] }
    private let store: Store

    init(store: Store, modelID: String? = nil, category: AIModelCategory? = nil) {
        let catalog = store.nativeModelCatalog.filter { category == nil || $0.category == category }
        self.catalog = catalog
        self.store = store
        let model = catalog.first { $0.id == modelID }
            ?? (category == .decision ? nil : catalog.first { $0.id == Self.defaultModelID })
            ?? catalog[0]
        selectedModelID = model.id
    }

    func select(_ id: String) {
        guard id != selectedModelID, catalog.contains(where: { $0.id == id }) else { return }
        selectedModelID = id
        refresh()
    }

    func refresh() { store.modelDownloads.transfer(for: selectedModel, store: store).refresh() }
    @discardableResult
    func install() -> String? { store.modelDownloads.transfer(for: selectedModel, store: store).install() }
    func stopDownload() { transfer?.stopDownload() }
}

@MainActor @Observable final class ModelTransfer {
    private(set) var state: LocalModelInstallState = .available
    private(set) var isDownloading = false
    private(set) var installedURL: URL?
    private(set) var downloadDirectory: URL?
    private(set) var completedDownloadID: String?
    var activeStatus: String? {
        guard isDownloading else { return nil }
        if case let .downloading(downloaded, total, _) = state {
            let progress = (Double(downloaded) / Double(total)).formatted(.percent.precision(.fractionLength(0)))
            return "Downloading \(progress)"
        }
        return "Preparing download…"
    }
    private let model: NativeModelDescriptor
    @ObservationIgnored private weak var store: (any ModelsProviderStore)?
    @ObservationIgnored private let onInstalled: () -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requestID: String?

    init(model: NativeModelDescriptor, store: any ModelsProviderStore, onInstalled: @escaping () -> Void) {
        self.model = model
        self.store = store
        self.onInstalled = onInstalled
    }

    func refresh() {
        guard requestID == nil else { return }
        run(install: false)
    }

    func install() -> String? {
        guard !isDownloading, state != .installed else { return nil }
        cancelRequest()
        run(install: true)
        return requestID
    }

    func stopDownload() {
        guard isDownloading else { return }
        cancelRequest()
        isDownloading = false
        state = .available
        refresh()
    }

    private func cancelRequest() {
        if let requestID { store?.cancelModelRequest(requestID) }
        requestID = nil
        task?.cancel()
        task = nil
    }

    private func run(install: Bool) {
        guard let store else { return }
        let priorState = state
        if install || state == .available { state = .checking }
        isDownloading = install
        let id = UUID().uuidString
        let modelID = model.id
        requestID = id
        let events = store.modelEvents(category: model.category, modelID: modelID, install: install,
                                       directory: nil, requestID: id)
        task = Task { [weak self] in
            var completed = false
            do {
                for try await data in events {
                    guard let self, requestID == id, !Task.isCancelled else { return }
                    let event = try JSONDecoder().decode(LocalModelEvent.self, from: data)
                    let reported = try event.state(for: modelID, installing: install)
                    if install, event.type == "result" {
                        completedDownloadID = id
                        isDownloading = false
                    }
                    if !install, reported == .available, case .failed = priorState { state = priorState }
                    else { state = reported }
                    if let model = event.result?.models?.first(where: { $0.id == modelID }) {
                        downloadDirectory = URL(fileURLWithPath: model.directory, isDirectory: true)
                        installedURL = model.installed ? model.path.map { URL(fileURLWithPath: $0) } : nil
                    }
                    if event.type == "result" { completed = true }
                }
                guard let self, requestID == id, !Task.isCancelled else { return }
                if !completed { state = .failed("The model installer stopped before completing. Retry the download.") }
            } catch is CancellationError {
                guard let self, requestID == id, !Task.isCancelled else { return }
                state = .available
            } catch {
                guard let self, requestID == id, !Task.isCancelled else { return }
                self.store?.cancelModelRequest(id)
                state = .failed(error.localizedDescription)
            }
            guard let self, requestID == id else { return }
            requestID = nil
            task = nil
            isDownloading = false
            if state == .installed {
                if install { refresh() }
                if priorState != .installed { onInstalled() }
            }
        }
    }
}

struct LocalModelEvent: Decodable {
    struct InventoryModel: Decodable { let id: String; let installed: Bool; let path: String?; let directory: String }
    struct Result: Decodable {
        let models: [InventoryModel]?
        let modelId: String?
        let installed: Bool?
    }
    let type: String
    let status: String?
    let downloaded: UInt64?
    let total: UInt64?
    let bytesPerSecond: UInt64?
    let result: Result?

    func state(for modelID: String, installing: Bool) throws -> LocalModelInstallState {
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
            case "downloading": return .downloading(downloaded: downloaded, total: total, bytesPerSecond: bytesPerSecond)
            case "ready" where downloaded == total: return .checking // Await the terminal result before saving.
            default: break
            }
        }
        throw AgentFailure(message: "Fritz’s model installer returned invalid progress. Retry the download.")
    }
}
