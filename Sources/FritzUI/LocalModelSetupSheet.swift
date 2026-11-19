import AppKit
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
        FritzDialog(state == .installed ? "Use Model" : "Download Model") {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Model").foregroundStyle(.secondary)
                        Text(model.name).fixedSize(horizontal: false, vertical: true)
                    }
                    if state != .installed {
                        GridRow {
                            Text("Download").foregroundStyle(.secondary)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: model.size), countStyle: .file))
                        }
                    }
                    GridRow {
                        Text("Memory").foregroundStyle(.secondary)
                        Text("\(model.memoryGB) GB recommended")
                            .foregroundStyle(memoryGB < model.memoryGB ? .orange : .secondary)
                    }
                    if state != .installed {
                        GridRow {
                            Text("Saving to").foregroundStyle(.secondary).accessibilityHidden(true)
                            ModelStorageDestination(storage: storage)
                                .labelsHidden()
                                .accessibilityElement(children: .contain)
                                .disabled(state.isBusy || isSaving)
                        }
                    }
                    if state == .installed, let installedDirectory {
                        GridRow {
                            Text("Stored in").foregroundStyle(.secondary)
                            Label(NSString(string: installedDirectory.path).abbreviatingWithTildeInPath, systemImage: "folder")
                                .lineLimit(1).truncationMode(.middle).help(installedDirectory.path)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                installationFeedback
                feedback
            }
            .padding(.horizontal, 24)
        } actions: {
            if isSaving {
                ProgressView().controlSize(.small).accessibilityLabel("Saving model")
                Spacer()
            }
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
            Button(primaryActionTitle, action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || isSaving)
        }
        .accessibilityElement(children: .contain)
        .padding(.vertical, 12)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .background { ModelSetupSheetSizing() }
        .presentationSizing(.fitted)
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

/// SwiftUI fits the sheet at presentation. Keep the attached window fitted as feedback changes.
private struct ModelSetupSheetSizing: NSViewRepresentable {
    func makeNSView(context: Context) -> SizingView { SizingView() }

    func updateNSView(_ view: SizingView, context: Context) {}

    final class SizingView: NSView {
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            resizeSheet()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resizeSheet()
        }

        private func resizeSheet() {
            // Resize after SwiftUI finishes laying out the sheet content.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window, window.sheetParent != nil,
                      let content = window.contentView,
                      frame.height > 0, abs(content.frame.height - frame.height) >= 1 else { return }
                window.setContentSize(NSSize(width: content.frame.width, height: frame.height))
            }
        }
    }
}
