import Fritz
import SwiftUI

/// Dedicated place to download Fritz's pinned local models, separate from provider setup.
struct ModelDownloadView: View {
    @State private var store: ModelDownloadStore
    @Environment(\.dismiss) private var dismiss
    private let hardware = LocalModelHardware.current

    init(agent: AgentClient) {
        _store = State(initialValue: ModelDownloadStore(agent: agent))
    }

    var body: some View {
        VStack(spacing: 0) {
            FritzManagementHeader("Download Models", description: "Verified models that run offline on this Mac · \(hardware.summary)")
            Divider()
            Group {
                if store.downloads.isEmpty, let error = store.error {
                    ContentUnavailableView {
                        Label("Models Unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { Task { await store.refresh() } }
                    }
                } else if store.downloads.isEmpty {
                    ProgressView("Checking installed models…").controlSize(.small)
                } else {
                    List(NativeModelDescriptor.catalog) { model in
                        if let download = store.downloads[model.id] {
                            ModelDownloadRow(model: model, download: download, hardware: hardware)
                        }
                    }
                    .listStyle(.plain)
                    .fritzListSurface()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) {
                Text(store.isDownloading
                     ? "Closing this window cancels downloads in progress."
                     : "Installed models appear in the chat model picker once a Fritz provider is added.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(FritzButtonStyle(.primary)).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(FritzWindowStyle.workspaceBackground)
        }
        .frame(width: 640, height: 460)
        .background(FritzWindowStyle.contentBackground)
        .buttonStyle(FritzButtonStyle())
        .task { await store.refresh() }
        .onDisappear { store.cancelAll() }
    }
}

private struct ModelDownloadRow: View {
    let model: NativeModelDescriptor
    let download: NativeLocalModel
    let hardware: LocalModelHardware

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name).font(.headline)
                HStack(spacing: 6) {
                    Text(model.downloadSummary)
                    Link("License", destination: model.licenseURL)
                }
                .font(.caption).foregroundStyle(.secondary)
                if let fitWarning {
                    Label(fitWarning, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            status
                .frame(width: 210, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var status: some View {
        switch download.state {
        case .available:
            Button("Download", systemImage: "arrow.down.circle") { download.install() }
                .accessibilityLabel("Download \(model.name)")
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Verifying…").font(.caption).foregroundStyle(.secondary)
                cancelButton
            }
        case let .downloading(downloaded, total):
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 3) {
                    ProgressView(value: Double(downloaded), total: Double(total))
                        .accessibilityLabel("Downloading \(model.name)")
                    Text("\(bytes(downloaded)) of \(bytes(total))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                cancelButton
            }
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            VStack(alignment: .trailing, spacing: 3) {
                Button("Retry", systemImage: "arrow.clockwise") { download.install() }
                    .accessibilityLabel("Retry downloading \(model.name)")
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(2).help(message)
            }
        }
    }

    private var cancelButton: some View {
        Button("Cancel Download", systemImage: "xmark.circle.fill") { download.cancel() }
            .labelStyle(.iconOnly).buttonStyle(FritzButtonStyle(.inline))
            .help("Cancel Download").accessibilityLabel("Cancel downloading \(model.name)")
    }

    private var fitWarning: String? {
        if hardware.memoryGB < model.memoryGB { return "This Mac has \(hardware.memoryGB) GB memory. A smaller model is recommended." }
        if !hardware.appleSilicon { return "Slower on Intel Macs." }
        return nil
    }

    private func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
