import Fritz
import SwiftUI

struct LocalModelDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: NativeLocalModel

    init(agent: AgentClient, modelID: String? = nil) {
        _model = State(initialValue: NativeLocalModel(agent: agent, modelID: modelID))
    }

    var body: some View {
        VStack(spacing: 0) {
            FritzManagementHeader("Download Local Model")
            Divider()
            Form {
                NativeLocalModelSection(modelID: Binding(
                    get: { model.selectedModelID },
                    set: { model.select($0) }
                ), state: model.state, hardware: .current)
            }
            .fritzSettingsFormStyle()
            Divider()
            HStack(spacing: 8) {
                Link("Model license", destination: model.selectedModel.licenseURL)
                Spacer()
                Button(model.state == .installed ? "Close" : "Cancel") {
                    model.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if model.state != .installed {
                    Button(downloadTitle) { model.install() }
                        .buttonStyle(FritzButtonStyle(.primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.state.isBusy)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(FritzWindowStyle.workspaceBackground)
        }
        .frame(width: 600, height: 300)
        .background(FritzWindowStyle.contentBackground)
        .buttonStyle(FritzButtonStyle())
        .task { model.refresh() }
        .onDisappear { model.cancel() }
    }

    private var downloadTitle: String {
        if case .failed = model.state { return "Retry Download" }
        return "Download"
    }
}
