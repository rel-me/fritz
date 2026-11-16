import Fritz
import SwiftUI

/// A single-model task uses a content-sized native sheet rather than a configuration page.
struct LocalModelSetupSheet<Feedback: View>: View {
    let model: NativeModelDescriptor
    let state: LocalModelInstallState
    let memoryGB: Int
    let storage: ModelStorage
    let installedDirectory: URL?
    let primaryActionTitle: String
    let canSubmit: Bool
    let isSaving: Bool
    let cancel: () -> Void
    let submit: () -> Void
    @ViewBuilder let feedback: Feedback

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Form {
                    LabeledContent("Model") {
                        Text(model.name).fixedSize(horizontal: false, vertical: true)
                    }
                    if state != .installed {
                        LabeledContent("Download", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: model.size), countStyle: .file))
                    }
                    LabeledContent("Memory") {
                        Text("\(model.memoryGB) GB recommended")
                            .foregroundStyle(memoryGB < model.memoryGB ? .orange : .secondary)
                    }
                    if state != .installed {
                        ModelStorageDestination(storage: storage)
                            .accessibilityElement(children: .contain)
                            .disabled(state.isBusy || isSaving)
                    }
                    if state == .installed, let installedDirectory {
                        LabeledContent("Stored in") {
                            Label(NSString(string: installedDirectory.path).abbreviatingWithTildeInPath, systemImage: "folder")
                                .lineLimit(1).truncationMode(.middle).help(installedDirectory.path)
                        }
                    }
                }
                .formStyle(.columns)
                .accessibilityElement(children: .contain)
                installationFeedback
                feedback
            }
            .accessibilityElement(children: .contain)
            .padding(20)
            .fixedSize(horizontal: false, vertical: true)
            .navigationTitle(state == .installed ? "Use Model" : "Download Model")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                        .keyboardShortcut(.cancelAction)
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(primaryActionTitle, action: submit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSubmit || isSaving)
                }
                ToolbarItem(placement: .status) {
                    if isSaving { ProgressView().controlSize(.small).accessibilityLabel("Saving model") }
                }
            }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .presentationSizing(.fitted)
        .buttonStyle(.automatic)
    }

    @ViewBuilder private var installationFeedback: some View {
        switch state {
        case .available, .installed: EmptyView()
        case .checking:
            ProgressView("Checking model…").progressViewStyle(.linear)
        case let .downloading(downloaded, total):
            ProgressView(value: Double(downloaded), total: Double(total)) {
                Text("Downloading…")
            } currentValueLabel: {
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(clamping: downloaded), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file))")
                    .monospacedDigit()
            }
            .progressViewStyle(.linear)
        case .failed(let message):
            Text(message).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}
