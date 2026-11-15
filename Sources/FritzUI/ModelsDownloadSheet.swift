import Fritz
import SwiftUI

public struct ModelsDownloadSheet<Store: ModelsProviderStore>: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ConfigurationNativeModel<Store>
    @State private var filters = NativeModelFilters()
    private let hardware: LocalModelHardware

    public init(store: Store, hardware: LocalModelHardware, modelID: String? = nil, category: AIModelCategory? = nil) {
        self.hardware = hardware
        _model = State(initialValue: ConfigurationNativeModel(store: store, modelID: modelID, category: category))
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ConfigurationLocalModelSection(filters: $filters, modelID: Binding(
                    get: { model.selectedModelID },
                    set: { model.select($0) }
                ), state: model.state, hardware: hardware, catalog: model.catalog)
                if hasVisibleSelection {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(model.selectedModel.name) · \(hardware.summary)")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.state != .installed {
                            HStack {
                                ConfigurationDownloadLocation(directory: model.downloadDirectory, choose: model.chooseDirectory)
                                    .disabled(model.state.isBusy)
                                    .layoutPriority(-1)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Download Local Model")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(hasVisibleSelection && model.state == .installed ? "Close" : "Cancel") {
                        model.cancel()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !hasVisibleSelection || model.state != .installed {
                        Button(downloadTitle) { if hasVisibleSelection { model.install() } }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!hasVisibleSelection || model.state.isBusy)
                    }
                }
            }
        }
        .frame(width: 840, height: 540)
        .buttonStyle(.automatic)
        .task { model.refresh() }
        .onDisappear { model.cancel() }
        .onChange(of: filters) { _, newFilters in
            if !hasVisibleSelection, let first = newFilters.models(in: model.catalog).first {
                model.select(first.id)
            }
        }
    }

    private var hasVisibleSelection: Bool {
        filters.models(in: model.catalog).contains { $0.id == model.selectedModelID }
    }

    private var downloadTitle: String {
        if hasVisibleSelection, case .failed = model.state { return "Retry Download" }
        return "Download"
    }
}
