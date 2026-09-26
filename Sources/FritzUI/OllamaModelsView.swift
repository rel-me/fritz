import SwiftUI

public struct OllamaModelItem: Identifiable, Sendable {
  public let id: String
  public let name: String
  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

/// Ollama download sheet presentation. The host owns connectivity and asynchronous work.
public struct OllamaModelsView<ModelDetails: View, ErrorContent: View>: View {
  @Binding var selectedModel: String
  let models: [OllamaModelItem]
  let connected: Bool
  let busy: Bool
  let status: String
  let error: String?
  let fraction: Double?
  let isSelectedModelInstalled: Bool
  let contentBackground: Color
  let openOllama: () -> Void
  let checkConnection: () -> Void
  let cancelOperation: () -> Void
  let cancel: () -> Void
  let install: () -> Void
  let modelDetails: ModelDetails
  let errorContent: (String) -> ErrorContent

  public init(
    selectedModel: Binding<String>, models: [OllamaModelItem], connected: Bool,
    busy: Bool, status: String, error: String?, fraction: Double?, isSelectedModelInstalled: Bool,
    contentBackground: Color, openOllama: @escaping () -> Void,
    checkConnection: @escaping () -> Void, cancelOperation: @escaping () -> Void,
    cancel: @escaping () -> Void, install: @escaping () -> Void,
    @ViewBuilder modelDetails: () -> ModelDetails,
    @ViewBuilder errorContent: @escaping (String) -> ErrorContent
  ) {
    _selectedModel = selectedModel
    self.models = models
    self.connected = connected
    self.busy = busy
    self.status = status
    self.error = error
    self.fraction = fraction
    self.isSelectedModelInstalled = isSelectedModelInstalled
    self.contentBackground = contentBackground
    self.openOllama = openOllama
    self.checkConnection = checkConnection
    self.cancelOperation = cancelOperation
    self.cancel = cancel
    self.install = install
    self.modelDetails = modelDetails()
    self.errorContent = errorContent
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Ollama Models").font(.headline)
      Form {
        Section {
          Picker("Model", selection: $selectedModel) {
            ForEach(models) { model in
              Text(model.name).tag(model.id)
            }
          }
          .disabled(busy)
        } footer: {
          modelDetails
        }
      }
      .formStyle(.grouped)
      .contentMargins(.vertical, 0, for: .scrollContent)
      .scrollContentBackground(.hidden)
      .background(contentBackground)
      .frame(height: 150)

      Text("Download and run models using Ollama on this Mac.")
        .font(.callout).foregroundStyle(.secondary)
      if !connected {
        HStack {
          Link("Install Ollama…", destination: URL(string: "https://ollama.com/download/mac")!)
          Button("Open Ollama", action: openOllama)
          Button("Check Connection", action: checkConnection)
        }
        .disabled(busy)
      }
      if busy {
        ProgressView(value: fraction)
        Button("Cancel Operation") { cancelOperation() }
      }
      Text(status).font(.callout).foregroundStyle(.secondary)
        .accessibilityIdentifier("local-models.status")
      if let error { errorContent(error) }
      Spacer(minLength: 0)
      HStack {
        Link("Model licenses", destination: URL(string: "https://ollama.com/library/qwen3")!)
        Spacer()
        Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
        Button(isSelectedModelInstalled ? "Add Provider" : "Download & Add", action: install)
          .buttonStyle(FritzButtonStyle(.primary))
          .keyboardShortcut(.defaultAction)
          .disabled(!connected || busy)
      }
    }
    .padding(20)
    .frame(width: 600, height: 450)
    .background(contentBackground)
    .buttonStyle(FritzButtonStyle())
  }
}
