import AppKit
import SwiftUI

public struct LocalModelStatusSheet: View {
    let store: ModelsStore
    let runtime: ModelsLocalRuntime
    let modelID: String
    let name: String
    let activeStatus: () -> (title: String, kvCacheBytes: UInt64?)?
    let canStopChats: () -> Bool
    let stopChats: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var policyError: String?

    public init(store: ModelsStore, runtime: ModelsLocalRuntime, modelID: String, name: String,
                activeStatus: @escaping () -> (title: String, kvCacheBytes: UInt64?)?,
                canStopChats: @escaping () -> Bool, stopChats: @escaping () -> Void) {
        self.store = store
        self.runtime = runtime
        self.modelID = modelID
        self.name = name
        self.activeStatus = activeStatus
        self.canStopChats = canStopChats
        self.stopChats = stopChats
    }

    private var session: ModelsRuntimeSession { runtime.sessions[modelID] ?? .init() }
    private var transfer: ModelTransfer? { store.modelDownloads[modelID] }
    private var canStopLocalAPI: Bool { session.status == .running || session.status == .starting }

    private var startPolicy: Binding<ModelsStartPolicy> {
        Binding(get: { runtime.policy(for: modelID) }, set: { policy in
            do {
                try runtime.setPolicy(policy, for: modelID)
                policyError = nil
            } catch { policyError = error.localizedDescription }
        })
    }

    public var body: some View {
        let status = activeStatus()
        let canStop = canStopLocalAPI || canStopChats()
        FritzDialog("Model Status", separatesActions: true) {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Model").foregroundStyle(.secondary)
                        Text(name).fixedSize(horizontal: false, vertical: true)
                    }
                    GridRow {
                        Text("Status").foregroundStyle(.secondary)
                        Text(status?.title ?? session.status.title)
                    }
                    if let bytes = status?.kvCacheBytes {
                        GridRow {
                            Text("KV Cache").foregroundStyle(.secondary)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .binary))
                        }
                    }
                    if let processID = session.processID {
                        GridRow {
                            Text("Local API PID").foregroundStyle(.secondary)
                            Text(String(processID)).monospacedDigit()
                        }
                    }
                    if canStopLocalAPI, let address = runtime.service.address {
                        GridRow {
                            Text("Local API Address").foregroundStyle(.secondary)
                            Text(address).textSelection(.enabled)
                        }
                    }
                    if let url = transfer?.installedURL {
                        GridRow {
                            Text("Installed at").foregroundStyle(.secondary)
                            Text((url.path as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1).truncationMode(.middle).help(url.path).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Picker("Start on", selection: startPolicy) {
                    ForEach(ModelsStartPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(runtime.policyError != nil)

                if let error = policyError ?? runtime.policyError ?? session.error ?? runtime.error {
                    Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 24)
        } actions: {
            if let url = transfer?.installedURL {
                Button("Open in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            if status != nil || canStop || session.status == .stopping {
                Button("Stop") {
                    if canStopLocalAPI { runtime.stop(modelID) }
                    stopChats()
                }
                .disabled(!canStop)
            } else {
                Button("Start") { runtime.start(modelID) }
                    .disabled(runtime.isLoading || !runtime.installedIDs.contains(modelID))
            }
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.top, 12)
        .frame(width: 460)
        .fritzFittedSheet()
        .task {
            if let model = store.nativeModelCatalog.first(where: { $0.id == modelID }) {
                store.modelDownloads.transfer(for: model, store: store).refresh()
            }
            await runtime.refresh()
        }
    }
}
