import Fritz
import Foundation
import Observation

/// Backs the Download Models sheet: one inventory read, then one installer per catalog model
/// so several downloads can run at once. Downloads are cancelled with the sheet.
@MainActor @Observable final class ModelDownloadStore {
    private(set) var downloads: [String: NativeLocalModel] = [:]
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored private let agent: AgentClient

    init(agent: AgentClient) { self.agent = agent }

    var isDownloading: Bool { downloads.values.contains { $0.state.isBusy } }

    func refresh() async {
        guard !isDownloading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let inventory: Inventory = try await agent.request("localModels.list")
            let installed = Set(inventory.models.filter(\.installed).map(\.id))
            downloads = Dictionary(uniqueKeysWithValues: NativeModelDescriptor.catalog.map {
                ($0.id, NativeLocalModel(agent: agent, modelID: $0.id, installed: installed.contains($0.id)))
            })
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func cancelAll() {
        for download in downloads.values { download.cancel() }
    }
}

private struct Inventory: Decodable {
    struct Model: Decodable { let id: String; let installed: Bool }
    let models: [Model]
}
