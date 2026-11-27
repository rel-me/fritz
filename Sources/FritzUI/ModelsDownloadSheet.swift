import Fritz
import SwiftUI

public struct ModelsDownloadSheet<Store: ModelsProviderStore>: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ConfigurationNativeModel<Store>
    @State private var filters = NativeModelFilters()
    private let storage: ModelStorage
    private let downloads: ModelDownloads
    private let hardware: LocalModelHardware

    public init(store: Store, hardware: LocalModelHardware, modelID: String? = nil, category: AIModelCategory? = nil) {
        self.hardware = hardware
        self.storage = store.modelStorage
        self.downloads = store.modelDownloads
        _model = State(initialValue: ConfigurationNativeModel(store: store, modelID: modelID, category: category))
    }

    public var body: some View {
        FritzDialog("Download Local Model") {
            VStack(spacing: 0) {
                ConfigurationLocalModelSection(filters: $filters, modelID: Binding(
                    get: { model.selectedModelID },
                    set: { model.select($0) }
                ), state: model.state, hardware: hardware, catalog: model.catalog, downloads: downloads)
                if hasVisibleSelection {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(model.selectedModel.name) · \(hardware.summary)")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.state != .installed {
                            HStack {
                                ModelStorageDestination(storage: storage)
                                    .disabled(model.state.isBusy)
                                    .layoutPriority(-1)
                                Spacer(minLength: 0)
                            }
                            if model.isDownloading {
                                Button("Stop Download") { model.stopDownload() }
                                    .buttonStyle(FritzButtonStyle())
                            } else {
                                Button(downloadTitle) { model.install() }
                                    .keyboardShortcut(.defaultAction)
                                    .buttonStyle(FritzButtonStyle(.primary))
                                    .disabled(model.state.isBusy || storage.isBusy)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                }
            }
        } actions: {
            Button("Close") { dismiss() }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.vertical, 12)
        .frame(width: 840, height: 540)
        .task { model.refresh() }
        .onChange(of: storage.info?.directory) { _, _ in model.refresh() }
        .onChange(of: filters) { _, newFilters in
            if !hasVisibleSelection, let first = newFilters.models(in: model.catalog, hardware: hardware).first {
                model.select(first.id)
            }
        }
    }

    private var hasVisibleSelection: Bool {
        filters.models(in: model.catalog, hardware: hardware).contains { $0.id == model.selectedModelID }
    }

    private var downloadTitle: String {
        if hasVisibleSelection, case .failed = model.state { return "Retry Download" }
        return "Download"
    }
}
