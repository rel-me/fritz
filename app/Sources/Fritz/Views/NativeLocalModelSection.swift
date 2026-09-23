import Fritz
import SwiftUI

/// Installation feedback belongs to provider setup, before a model can be used.
enum NativeModelInstallState: Equatable, Sendable {
    case available
    case checking
    case downloading(downloaded: UInt64, total: UInt64)
    case installed
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .checking, .downloading: true
        case .available, .installed, .failed: false
        }
    }
}

struct NativeLocalModelSection: View {
    @Binding var modelID: String
    let state: NativeModelInstallState
    let hardware: LocalModelHardware

    private var model: NativeModelDescriptor {
        NativeModelDescriptor.catalog.first { $0.id == modelID }!
    }

    var body: some View {
        Section {
            Picker("Model", selection: $modelID) {
                ForEach(NativeModelDescriptor.catalog) { model in
                    Text(model.name).tag(model.id)
                }
            }
            .disabled(state.isBusy)
            .accessibilityIdentifier("native-model-picker")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.downloadSummary)
                if hardware.memoryGB < model.memoryGB {
                    Text("This Mac has \(hardware.memoryGB) GB memory. A smaller model is recommended.")
                }
                if !hardware.appleSilicon {
                    Text("Slower on Intel Macs.")
                }
                switch state {
                case .available:
                    EmptyView()
                case .checking:
                    ProgressView("Verifying model…").controlSize(.small)
                case .installed:
                    Label("Installed", systemImage: "checkmark.circle")
                case let .downloading(downloaded, total):
                    ProgressView(value: Double(downloaded), total: Double(total))
                        .accessibilityLabel("Downloading local model")
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(downloaded), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))")
                        .monospacedDigit()
                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
