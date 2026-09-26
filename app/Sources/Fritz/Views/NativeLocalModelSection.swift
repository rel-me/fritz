import Fritz
import SwiftUI

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

    private var selection: Binding<String?> {
        Binding(
            get: { modelID },
            set: { if let id = $0, !state.isBusy { modelID = id } }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(NativeModelDescriptor.catalog, selection: selection) {
                TableColumn("Name") { model in
                    Text(model.name).lineLimit(1).help(model.name)
                }
                .width(min: 200, ideal: 250)
                TableColumn("Type") { _ in
                    // The downloadable catalog currently contains chat models only.
                    Text("LLM")
                }
                .width(70)
                TableColumn("Size / Status") { entry in
                    HStack(spacing: 6) {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                            .monospacedDigit()
                        if entry.id == modelID {
                            Text(statusTitle).foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                }
                .width(min: 160, ideal: 180)
                TableColumn("Hardware Requirements") { model in
                    Text("\(model.memoryGB) GB RAM recommended")
                        .foregroundStyle(hardware.memoryGB < model.memoryGB ? .orange : .secondary)
                }
                .width(min: 210, ideal: 230)
            }
            .fritzListSurface()
            .disabled(state.isBusy)
            .accessibilityLabel("Downloadable models")
            .accessibilityIdentifier("native-model-list")

            VStack(alignment: .leading, spacing: 6) {
                Text("\(model.name) · \(hardware.summary)")
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
                        .textSelection(.enabled)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
    }

    private var statusTitle: String {
        switch state {
        case .available: "Available"
        case .checking: "Checking…"
        case .downloading: "Downloading…"
        case .installed: "Installed"
        case .failed: "Failed"
        }
    }
}
