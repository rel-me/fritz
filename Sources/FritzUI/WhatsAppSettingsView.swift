import AppKit
import CoreImage.CIFilterBuiltins
import Fritz
import SwiftUI

public struct WhatsAppSettingsView: View {
  @State private var connection: WhatsAppConnection
  @State private var groups: [WhatsAppGroup]
  @State private var selectedGroupID = ""
  @State private var feedback: String?
  @State private var isWorking = false
  @State private var showsRemoveConfirmation = false
  @State private var refreshGeneration = 0
  @State private var operation: Task<Void, Never>?
  private let refreshesOnAppear: Bool
  private let client: IntegrationClient
  private let appName: String
  private let capabilities: String
  private let contentBackground: Color

  public init(
    client: IntegrationClient, appName: String, capabilities: String,
    contentBackground: Color = Color(nsColor: .windowBackgroundColor),
    connection: WhatsAppConnection = .init(), groups: [WhatsAppGroup] = [],
    refreshesOnAppear: Bool = true
  ) {
    self.client = client
    self.appName = appName
    self.capabilities = capabilities
    self.contentBackground = contentBackground
    _connection = State(initialValue: connection)
    _groups = State(initialValue: groups)
    _selectedGroupID = State(initialValue: connection.destination?.id ?? "")
    self.refreshesOnAppear = refreshesOnAppear
  }

  public var body: some View {
    Form {
      Section {
        Toggle(
          "Enabled",
          isOn: Binding(
            get: { connection.enabled },
            set: { enabled in
              perform {
                let next = try await client.setWhatsAppEnabled(enabled)
                guard !Task.isCancelled else { return }
                connection = next
              }
            }
          )
        )
        .disabled(isWorking)
        if connection.hasConnection {
          Button("Remove Connection…", role: .destructive) { showsRemoveConfirmation = true }
            .disabled(isWorking)
        } else if connection.enabled {
          Button("Connect WhatsApp") {
            perform { connection = try await client.connectWhatsApp() }
          }
          .disabled(isWorking)
        }
        if connection.enabled && connection.hasConnection && !connection.isConnected
          && !connection.isConnecting && !connection.isPairing
        {
          Button(connection.phase == "expired" ? "New QR Code" : "Connect WhatsApp") {
            perform { connection = try await client.connectWhatsApp() }
          }
          .disabled(isWorking)
        }
      } header: {
        IntegrationSettingsPageTitle("WhatsApp")
      } footer: {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            if connection.isConnecting {
              ProgressView().controlSize(.small)
              Text(connection.title)
            } else {
              Label(
                connection.title,
                systemImage: connection.isConnected ? "checkmark.circle.fill" : "phone.bubble"
              )
              .foregroundStyle(connection.isConnected ? Color.green : Color.secondary)
            }
          }
          if !connection.enabled {
            Text("WhatsApp is paused. Your linked account and group are kept. Enable it to resume.")
          } else if !connection.saved {
            Text("Connect your WhatsApp account to choose a group for \(appName) notifications.")
          }
          if connection.isPairing {
            pairingContent
          }
          if let message = connection.message { Text(message).textSelection(.enabled) }
          if let feedback { Text(feedback).textSelection(.enabled) }
          Text(
            "This connection uses an unofficial WhatsApp client. WhatsApp changes may interrupt the connection or restrict your account."
          )
        }
      }

      if connection.saved && connection.destination != nil {
        Section {
          Toggle(
            "Remote control",
            isOn: Binding(
              get: { connection.remoteEnabled == true },
              set: { enabled in
                perform { connection = try await client.setWhatsAppRemoteEnabled(enabled) }
              }
            )
          )
          .disabled(isWorking || !connection.enabled)
        } header: {
          Text("Use \(appName) remotely")
        } footer: {
          Text(capabilities)
        }
      }

      if connection.isConnected || connection.destination != nil {
        Section {
          HStack {
            Picker(
              "Group",
              selection: Binding(
                get: { selectedGroupID },
                set: { id in saveGroup(id) }
              )
            ) {
              if connection.destination == nil {
                Text("Choose a group").tag("")
              }
              if let saved = connection.destination, !groups.contains(where: { $0.id == saved.id })
              {
                Text(saved.name).tag(saved.id)
              }
              ForEach(groups) { group in
                Text(groupLabel(group)).tag(group.id)
              }
            }
            Button {
              perform { try await refreshGroups() }
            } label: {
              Image(systemName: "arrow.clockwise")
            }
            .help("Refresh groups")
            .accessibilityLabel("Refresh groups")
          }
          .disabled(isWorking || !connection.isConnected)
        } header: {
          Text("Notification group")
        } footer: {
          VStack(alignment: .leading, spacing: 8) {
            Text(
              "Group changes save automatically. Choosing a group does not send a message or enable an Action."
            )
            if connection.isConnected && groups.isEmpty {
              Text("No groups loaded. Refresh to find your WhatsApp groups.")
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .contentMargins(.vertical, 0, for: .scrollContent)
    .scrollContentBackground(.hidden)
    .background(contentBackground)
    .fritzButtonSize(.regular)
    .buttonStyle(FritzButtonStyle())
    .confirmationDialog("Remove WhatsApp connection?", isPresented: $showsRemoveConfirmation) {
      Button("Remove Connection", role: .destructive) {
        perform {
          connection = try await client.removeWhatsAppConnection()
          groups = []
          selectedGroupID = ""
          feedback =
            "Connection removed from \(appName). You can also remove \(appName) in WhatsApp’s Linked Devices."
        }
      }
    } message: {
      Text("\(appName) will stop connecting and remove the saved account and group from this Mac.")
    }
    .task {
      guard refreshesOnAppear else { return }
      while !Task.isCancelled {
        if !isWorking { await refresh() }
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
      }
    }
    .onDisappear {
      refreshGeneration += 1
      operation?.cancel()
    }
  }

  @ViewBuilder private var pairingContent: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      if let expires = connection.expiresAt, expires > context.date.timeIntervalSince1970,
        let code = connection.qr, let path = qrPath(code)
      {
        VStack(alignment: .leading, spacing: 8) {
          path
            .fill(Color.black)
            .frame(width: 200, height: 200)
            .padding(12)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("WhatsApp pairing QR code. Scan with your phone.")
          Text(
            "On your phone, open WhatsApp → Settings → Linked Devices → Link a Device, then scan this code."
          )
          Text("Keep this panel open while pairing. The code refreshes automatically.")
            .foregroundStyle(.secondary)
        }
      } else {
        Text("Waiting for a fresh QR code…")
      }
    }
  }

  private func qrPath(_ value: String) -> Path? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(value.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let width = Int(output.extent.width)
    let height = Int(output.extent.height)
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    CIContext(options: [.useSoftwareRenderer: true]).render(
      output, toBitmap: &pixels, rowBytes: width * 4,
      bounds: output.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
    )
    let unit = 200.0 / Double(width)
    return Path { path in
      for y in 0..<height {
        for x in 0..<width where pixels[(y * width + x) * 4] < 128 {
          path.addRect(CGRect(x: Double(x) * unit, y: Double(y) * unit, width: unit, height: unit))
        }
      }
    }
  }

  private func groupLabel(_ group: WhatsAppGroup) -> String {
    groups.filter { $0.name == group.name }.count > 1 ? "\(group.name) (\(group.id))" : group.name
  }

  private func saveGroup(_ id: String) {
    guard !isWorking, !id.isEmpty, id != connection.destination?.id else { return }
    selectedGroupID = id
    perform {
      do {
        let next = try await client.selectWhatsAppGroup(id)
        guard !Task.isCancelled else { return }
        connection = next
        selectedGroupID = next.destination?.id ?? ""
      } catch {
        selectedGroupID = connection.destination?.id ?? ""
        throw error
      }
    }
  }

  private func perform(_ action: @escaping @MainActor () async throws -> Void) {
    guard !isWorking else { return }
    isWorking = true
    refreshGeneration += 1
    feedback = nil
    operation = Task { @MainActor in
      defer {
        isWorking = false
        operation = nil
      }
      do { try await action() } catch is CancellationError {} catch {
        if !Task.isCancelled { feedback = error.localizedDescription }
      }
    }
  }

  private func refresh() async {
    let generation = refreshGeneration
    do {
      let next = try await client.whatsAppConnection()
      guard !Task.isCancelled, !isWorking, generation == refreshGeneration else { return }
      let becameConnected = next.isConnected && !connection.isConnected
      connection = next
      selectedGroupID = next.destination?.id ?? ""
      if becameConnected {
        isWorking = true
        defer { isWorking = false }
        do { try await refreshGroups() } catch {
          if !Task.isCancelled { feedback = error.localizedDescription }
        }
      }
    } catch {
      guard !Task.isCancelled, !isWorking, generation == refreshGeneration else { return }
      connection.phase = "error"
      connection.qr = nil
      feedback = error.localizedDescription
    }
  }

  private func refreshGroups() async throws {
    let next = try await client.whatsAppGroups()
    guard !Task.isCancelled else { return }
    groups = next
    selectedGroupID = connection.destination?.id ?? ""
  }
}
