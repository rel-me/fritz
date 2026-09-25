import Fritz
import SwiftUI

struct LocalModelsView: View {
    @Bindable var store: LocalModelRuntimeStore
    @State private var isDownloading = false

    private var installed: [NativeModelDescriptor] {
        NativeModelDescriptor.catalog.filter { store.installedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            FritzManagementHeader("Local Models", description: "Serve installed models to Ollama-compatible clients on this Mac.") {
                HStack(spacing: 6) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                        .disabled(store.isLoading).help("Refresh installed models")
                    Button("Download Models", systemImage: "arrow.down.circle") { isDownloading = true }
                        .help("Download Models")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(FritzButtonStyle(.floating))
            }
            if installed.isEmpty {
                ContentUnavailableView {
                    Label("No Installed Local Models", systemImage: "cpu")
                } description: {
                    Text("Download a Fritz model to start a local API session.")
                } actions: {
                    Button("Download Models") { isDownloading = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(installed) { model in
                    let session = store.sessions[model.id] ?? .init()
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.name).font(.headline)
                            Text(model.id).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Label(statusName(session.status), systemImage: session.status == .running ? "circle.fill" : "circle")
                                .foregroundStyle(session.status == .running ? .green : .secondary)
                            if let pid = session.processID { Text("PID \(pid)").font(.caption).foregroundStyle(.secondary) }
                            if let address = session.address { Text(address).font(.caption).textSelection(.enabled) }
                            if let error = session.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).help(error) }
                        }
                        .frame(width: 190, alignment: .leading)
                        HStack(spacing: 6) {
                            if session.status == .running || session.status == .starting {
                                Button("Stop") { store.stop(model.id) }
                                Button("Restart") { store.restart(model.id) }
                            } else {
                                Button("Start") { store.start(model.id) }
                            }
                        }
                        .buttonStyle(FritzButtonStyle(.inline))
                        .frame(width: 125, alignment: .trailing)
                    }
                    .padding(.vertical, 6)
                }
                .listStyle(.plain)
                .fritzListSurface()
            }
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).textSelection(.enabled).padding(12)
            }
        }
        .background(FritzWindowStyle.workspaceBackground)
        .task { await store.refresh() }
        .sheet(isPresented: $isDownloading, onDismiss: { Task { await store.refresh() } }) {
            ModelDownloadView(agent: store.agent)
        }
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
