import SwiftUI

public enum LocalModelInstallState: Equatable, Sendable {
  case available
  case checking
  case downloading(downloaded: UInt64, total: UInt64)
  case installed
  case failed(String)

  public var isBusy: Bool {
    switch self {
    case .checking, .downloading: true
    case .available, .installed, .failed: false
    }
  }
}

public struct LocalModelInstallItem: Identifiable, Sendable {
  public let id: String
  public let name: String
  public let downloadSummary: String
  public let memoryGB: Int

  public init(id: String, name: String, downloadSummary: String, memoryGB: Int) {
    self.id = id
    self.name = name
    self.downloadSummary = downloadSummary
    self.memoryGB = memoryGB
  }
}

/// A model catalog and installation feedback. Hosts own downloads and cancellation.
public struct LocalModelInstallSection<ErrorContent: View>: View {
  @Binding var modelID: String
  let models: [LocalModelInstallItem]
  let state: LocalModelInstallState
  let memoryGB: Int
  let appleSilicon: Bool
  let error: (String) -> ErrorContent

  public init(
    modelID: Binding<String>, models: [LocalModelInstallItem], state: LocalModelInstallState,
    memoryGB: Int, appleSilicon: Bool, @ViewBuilder error: @escaping (String) -> ErrorContent
  ) {
    _modelID = modelID
    self.models = models
    self.state = state
    self.memoryGB = memoryGB
    self.appleSilicon = appleSilicon
    self.error = error
  }

  private var model: LocalModelInstallItem? { models.first { $0.id == modelID } }

  public var body: some View {
    Section {
      Picker("Model", selection: $modelID) {
        ForEach(models) { model in
          Text(model.name).tag(model.id)
        }
      }
      .disabled(state.isBusy)
    } footer: {
      VStack(alignment: .leading, spacing: 6) {
        if let model { Text(model.downloadSummary) }
        if let model, memoryGB < model.memoryGB {
          Text("This Mac has \(memoryGB) GB memory. A smaller model is recommended.")
        }
        if !appleSilicon {
          Text("Slower on Intel Macs.")
        }
        switch state {
        case .available:
          EmptyView()
        case .checking:
          ProgressView("Verifying model…").controlSize(.small)
        case .installed:
          Label("Installed", systemImage: "checkmark.circle")
        case .downloading(let downloaded, let total):
          ProgressView(value: Double(downloaded), total: Double(total))
            .accessibilityLabel("Downloading local model")
          Text(
            "\(ByteCountFormatter.string(fromByteCount: Int64(downloaded), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))"
          )
          .monospacedDigit()
        case .failed(let message):
          error(message)
        }
      }
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}
