import SwiftUI

public struct ServiceSettingsView: View {
  private let configuration: ServiceSettingsConfiguration
  private let showLicenses: () -> Void
  public init(configuration: ServiceSettingsConfiguration, showLicenses: @escaping () -> Void) {
    self.configuration = configuration
    self.showLicenses = showLicenses
  }

  public var body: some View {
    Form {
      Section {
        LabeledContent("Status") {
          Label(serviceStatusText, systemImage: serviceStatusSymbol)
            .foregroundStyle(serviceStatusColor)
        }
        LabeledContent("Control Worker", value: workerStatusText)
      } header: {
        IntegrationSettingsPageTitle("Service") {
          IntegrationSettingsItemLabel(
            title: "Local Service",
            help: "\(configuration.appName).app supervises this agent "
              + "and restarts it if it stops responding."
          )
        }
      }

      if let recovery = configuration.recovery, recovery.issueCount > 0 {
        Section {
          Button("Show Recovery Report") {
            NSWorkspace.shared.activateFileViewerSelecting([
              URL(fileURLWithPath: recovery.reportPath)
            ])
          }
        } header: {
          Text("Data Recovery")
        } footer: {
          Text(recovery.message)
        }
      }

      Section("Connection") {
        LabeledContent("API Endpoint") {
          Text(apiEndpoint)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
        }
        LabeledContent("Agent Port", value: String(configuration.agentPort))
        if let port = configuration.auxiliaryPort {
          LabeledContent(port.label, value: port.value)
        }
      }

      Section {
        LabeledContent("Version", value: configuration.version ?? "—")
        LabeledContent("Process ID", value: processIDText)
        LabeledContent(
          "Owner",
          value: "\(configuration.appName).app"
        )
      } header: {
        Text("Process")
      } footer: {
        Link("Open RPC Documentation", destination: configuration.documentationURL)
      }

      Section("Licenses") {
        Button("View Open Source Licenses", action: showLicenses)
      }
    }
    .formStyle(.grouped)
    .contentMargins(.vertical, 0, for: .scrollContent)
    .scrollContentBackground(.hidden)
    .background(configuration.contentBackground)
    .fritzButtonSize(.regular)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var serviceStatusText: String { configuration.status }
  private var serviceStatusSymbol: String {
    configuration.connected
      ? "checkmark.circle.fill"
      : configuration.starting ? "clock.fill" : "exclamationmark.triangle.fill"
  }
  private var serviceStatusColor: Color {
    configuration.connected ? .green : configuration.starting ? .secondary : .red
  }
  private var workerStatusText: String { configuration.workerStatus }
  private var apiEndpoint: String { configuration.endpoint }
  private var processIDText: String { configuration.processID }
}

public struct ServiceSettingsConfiguration {
  public struct Field {
    public let label: String
    public let value: String
    public init(_ label: String, _ value: String) {
      self.label = label
      self.value = value
    }
  }
  public struct Recovery {
    public let issueCount: Int
    public let reportPath: String
    public let message: String
    public init(issueCount: Int, reportPath: String, message: String) {
      self.issueCount = issueCount
      self.reportPath = reportPath
      self.message = message
    }
  }
  public var appName: String
  public var status: String
  public var connected: Bool
  public var starting: Bool
  public var workerStatus: String
  public var endpoint: String
  public var agentPort: Int
  public var auxiliaryPort: Field?
  public var version: String?
  public var processID: String
  public var documentationURL: URL
  public var recovery: Recovery?
  public var contentBackground: Color
  public init(
    appName: String, status: String, connected: Bool, starting: Bool, workerStatus: String,
    endpoint: String, agentPort: Int, auxiliaryPort: Field? = nil, version: String?,
    processID: String, documentationURL: URL, recovery: Recovery? = nil,
    contentBackground: Color = Color(nsColor: .windowBackgroundColor)
  ) {
    self.appName = appName
    self.status = status
    self.connected = connected
    self.starting = starting
    self.workerStatus = workerStatus
    self.endpoint = endpoint
    self.agentPort = agentPort
    self.auxiliaryPort = auxiliaryPort
    self.version = version
    self.processID = processID
    self.documentationURL = documentationURL
    self.recovery = recovery
    self.contentBackground = contentBackground
  }
}
