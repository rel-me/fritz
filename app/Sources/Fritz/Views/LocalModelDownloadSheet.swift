import Fritz
import SwiftUI

struct LocalModelDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: NativeLocalModel
    @State private var filters = NativeModelFilters()

    init(agent: AgentClient, modelID: String? = nil, category: AIModelCategory? = nil) {
        _model = State(initialValue: NativeLocalModel(agent: agent, modelID: modelID, category: category))
    }

    var body: some View {
        VStack(spacing: 0) {
            FritzManagementHeader("Download Local Model")
            Divider()
            NativeLocalModelSection(filters: $filters, modelID: Binding(
                get: { model.selectedModelID },
                set: { model.select($0) }
            ), state: model.state, hardware: .current, catalog: model.catalog)
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
                        .disabled(!hasVisibleSelection || model.state.isBusy)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(FritzWindowStyle.workspaceBackground)
        }
        .frame(width: 840, height: 540)
        .background(FritzWindowStyle.contentBackground)
        .buttonStyle(FritzButtonStyle())
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
