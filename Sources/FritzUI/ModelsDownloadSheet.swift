import AppKit
import Fritz
import SwiftUI

public struct ModelsDownloadSheet<Store: ModelsProviderStore>: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ConfigurationNativeModel<Store>
    @State private var directoryPanel: NSOpenPanel?
    @State private var filters = NativeModelFilters()

    public init(store: Store, modelID: String? = nil, category: AIModelCategory? = nil) {
        _model = State(initialValue: ConfigurationNativeModel(store: store, modelID: modelID, category: category))
    }

    public var body: some View {
        VStack(spacing: 0) {
            ConfigurationManagementHeader("Download Local Model")
            Divider()
            ConfigurationLocalModelSection(filters: $filters, modelID: Binding(
                get: { model.selectedModelID },
                set: { model.select($0) }
            ), state: model.state, hardware: .current, catalog: model.catalog)
            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Download Folder").font(.callout.weight(.medium))
                    if let storage = model.storage {
                        Text(storage.directory).font(.callout).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(storage.directory)
                            .textSelection(.enabled)
                        if storage.isOverridden {
                            Text("Set by FRITZ_MODELS_DIR").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Button("Choose…", action: chooseDirectory)
                    .disabled(model.state.isBusy || model.storage?.isOverridden == true)
                    .accessibilityIdentifier("model-download-folder")
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            HStack(spacing: 8) {
                if hasVisibleSelection {
                    Link("Model license", destination: model.selectedModel.licenseURL)
                }
                Spacer()
                Button(hasVisibleSelection && model.state == .installed ? "Close" : "Cancel") {
                    model.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if !hasVisibleSelection || model.state != .installed {
                    Button(downloadTitle) { if hasVisibleSelection { model.install() } }
                        .buttonStyle(FritzButtonStyle(.primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(!hasVisibleSelection || model.state.isBusy || model.storage == nil)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(ModelsConfigurationStyle.workspaceBackground)
        }
        .frame(width: 840, height: 540)
        .background(ModelsConfigurationStyle.contentBackground)
        .buttonStyle(FritzButtonStyle())
        .task { model.refresh() }
        .onDisappear { directoryPanel?.cancel(nil); model.cancel() }
        .onChange(of: filters) { _, newFilters in
            if !hasVisibleSelection, let first = newFilters.models(in: model.catalog).first {
                model.select(first.id)
            }
        }
    }

    private func chooseDirectory() {
        guard directoryPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.preventsApplicationTerminationWhenModal = false
        panel.title = "Download Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let storage = model.storage { panel.directoryURL = URL(fileURLWithPath: storage.directory) }
        directoryPanel = panel
        panel.begin { response in
            directoryPanel = nil
            if response == .OK, let directory = panel.url { model.changeDirectory(directory) }
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
