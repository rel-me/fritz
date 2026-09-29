import Fritz
import FritzUI
import SwiftUI

struct LocalModelsView: View {
    @Bindable var store: LocalModelRuntimeStore
    let downloadModel: () -> Void

    private var installed: [NativeModelDescriptor] {
        NativeModelDescriptor.catalog.filter { store.installedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ModelManagementHeader("Local Models", background: FritzWindowStyle.workspaceBackground) {
                Button("Download Models", systemImage: "arrow.down", action: downloadModel)
                    .labelStyle(.iconOnly)
                    .buttonStyle(FritzButtonStyle(.floating, shape: .circle))
                    .controlSize(.extraLarge)
                    .help("Download Local Model")
            }
            LocalModelsList(models: installed.map { model in
                let session = store.sessions[model.id] ?? .init()
                return LocalModelListItem(
                    id: model.id, name: model.name, modelID: model.id,
                    status: statusName(session.status), isRunning: session.status == .running,
                    processID: session.processID, detail: session.address, errorMessage: session.error
                )
            }) { modelID in
                HStack(spacing: 6) {
                    let status = store.sessions[modelID]?.status ?? .stopped
                    if status == .running || status == .starting {
                        Button("Stop") { store.stop(modelID) }
                        Button("Restart") { store.restart(modelID) }
                    } else {
                        Button("Start") { store.start(modelID) }
                    }
                }
            }
            .fritzListSurface()
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).textSelection(.enabled).padding(12)
            }
        }
        .background(FritzWindowStyle.workspaceBackground)
        .task { await store.refresh() }
    }

    private func statusName(_ status: LocalModelRuntimeStore.Session.Status) -> String {
        switch status {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .failed: "Failed"
        }
    }
}
