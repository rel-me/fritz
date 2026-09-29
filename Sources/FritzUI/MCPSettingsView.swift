import AppKit
import Fritz
import SwiftUI

public struct MCPSettingsView: View {
  private let appName: String
  private let agentConnected: Bool
  private let agentStatus: String
  private let connection: MCPConnection?
  private let toolCount: Int
  private let documentationURL: URL
  private let contentBackground: Color
  public init(
    appName: String, agentConnected: Bool, agentStatus: String, connection: MCPConnection?,
    toolCount: Int, documentationURL: URL,
    contentBackground: Color = Color(nsColor: .windowBackgroundColor)
  ) {
    self.appName = appName
    self.agentConnected = agentConnected
    self.agentStatus = agentStatus
    self.connection = connection
    self.toolCount = toolCount
    self.documentationURL = documentationURL
    self.contentBackground = contentBackground
  }

  @State private var feedback: String?
  @State private var feedbackIsError = false
  @State private var connectionTest: Task<Void, Never>?

  public var body: some View {
    Form {
      Section {
        LabeledContent("Status") {
          Label(
            mcpIsAvailable ? "Ready on demand" : "Unavailable",
            systemImage: mcpIsAvailable
              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
          )
          .foregroundStyle(mcpIsAvailable ? .green : .red)
        }

        LabeledContent("Lifecycle", value: "Launched by each MCP client")
        LabeledContent("Agent Connection") {
          Label(
            agentConnected ? "Connected" : agentStatus,
            systemImage: agentConnected
              ? "checkmark.circle.fill" : "clock.fill"
          )
          .foregroundStyle(agentConnected ? .green : .secondary)
        }
      } header: {
        IntegrationSettingsPageTitle("MCP") {
          IntegrationSettingsItemLabel(
            title: "MCP Adapter",
            help: "Each MCP client starts its own adapter process, which forwards "
              + "requests to the local \(appName) service."
          )
        }
      }

      Section {
        LabeledContent("Command") {
          HStack {
            Text(mcpExecutablePath)
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
              .lineLimit(1)
              .truncationMode(.middle)
              .help(mcpExecutablePath)
            Button("Copy configuration", action: copyConfiguration)
              .disabled(!mcpIsAvailable)
              .fixedSize()
            Button(connectionTest == nil ? "Test connection" : "Testing…", action: testConnection)
              .disabled(!mcpIsAvailable || connectionTest != nil)
              .fixedSize()
          }
        }
        .accessibilityElement(children: .contain)
        LabeledContent("Transport", value: "Standard I/O (stdio)")
      } header: {
        Text("Connection")
      } footer: {
        if let feedback {
          Text(feedback)
            .foregroundStyle(feedbackIsError ? Color.red : Color.secondary)
            .textSelection(.enabled)
        }
      }

      Section {
        LabeledContent("Tools", value: String(toolCount))
        LabeledContent("Current Revision", value: "2026-07-28")
        LabeledContent("Legacy Compatibility", value: "2025-11-25")
      } header: {
        Text("Protocol")
      } footer: {
        Link("Open MCP Documentation", destination: documentationURL)
      }
    }
    .onDisappear {
      connectionTest?.cancel()
      connectionTest = nil
    }
    .formStyle(.grouped)
    .contentMargins(.vertical, 0, for: .scrollContent)
    .scrollContentBackground(.hidden)
    .background(contentBackground)
    .fritzButtonSize(.regular)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func copyConfiguration() {
    guard let connection else { return }
    do {
      let configuration = try connection.configuration()
      NSPasteboard.general.clearContents()
      guard NSPasteboard.general.setString(configuration, forType: .string) else {
        throw MCPConnection.ConnectionError.failed("Could not copy configuration.")
      }
      feedbackIsError = false
      feedback = "Configuration copied."
    } catch {
      feedbackIsError = true
      feedback = error.localizedDescription
    }
  }

  private func testConnection() {
    guard let connection, connectionTest == nil else { return }
    feedback = nil
    connectionTest = Task { @MainActor in
      defer { connectionTest = nil }
      do {
        try await connection.test()
        feedbackIsError = false
        feedback = "Connected to \(appName) through MCP."
      } catch is CancellationError {
        return
      } catch {
        feedbackIsError = true
        feedback = error.localizedDescription
      }
    }
  }

  private var mcpExecutableURL: URL? {
    connection?.executableURL
  }

  private var mcpExecutablePath: String {
    mcpExecutableURL?.path ?? "Bundled MCP executable not found"
  }

  private var mcpIsAvailable: Bool {
    guard let mcpExecutableURL else {
      return false
    }
    return FileManager.default.isExecutableFile(atPath: mcpExecutableURL.path)
  }
}
