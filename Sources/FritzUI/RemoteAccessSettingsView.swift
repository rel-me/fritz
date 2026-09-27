import Fritz
import SwiftUI

public struct RemoteAccessSettingsView: View {
  @State private var status: RemoteAccessStatus
  @State private var feedback: String?
  @State private var isWorking = false
  @State private var pairingCode: String?
  @State private var pairingExpires: Date?
  @State private var operation: Task<Void, Never>?
  @State private var generation = 0
  @AppStorage private var bind: String
  @AppStorage private var origin: String
  @AppStorage private var certificate: String
  @AppStorage private var privateKey: String
  private let refreshesOnAppear: Bool
  private let client: IntegrationClient
  private let appName: String
  private let capabilities: String
  private let contentBackground: Color

  public init(
    preferencesPrefix: String, client: IntegrationClient, appName: String, capabilities: String,
    contentBackground: Color = Color(nsColor: .windowBackgroundColor),
    status: RemoteAccessStatus = .init(), feedback: String? = nil, isWorking: Bool = false,
    pairingCode: String? = nil, refreshesOnAppear: Bool = true
  ) {
    _bind = AppStorage(wrappedValue: "127.0.0.1:17443", preferencesPrefix + "Bind")
    _origin = AppStorage(wrappedValue: "https://localhost:17443", preferencesPrefix + "Origin")
    _certificate = AppStorage(wrappedValue: "", preferencesPrefix + "Certificate")
    _privateKey = AppStorage(wrappedValue: "", preferencesPrefix + "PrivateKey")
    self.client = client
    self.appName = appName
    self.capabilities = capabilities
    self.contentBackground = contentBackground
    _status = State(initialValue: status)
    _feedback = State(initialValue: feedback)
    _isWorking = State(initialValue: isWorking)
    _pairingCode = State(initialValue: pairingCode)
    _pairingExpires = State(initialValue: pairingCode == nil ? nil : .distantFuture)
    self.refreshesOnAppear = refreshesOnAppear
  }

  public var body: some View {
    Form {
      Section {
        if status.enabled {
          Button("Disable Remote Access", role: .destructive) {
            perform {
              .status(try await client.remoteAccess("disable"))
            }
          }
        } else {
          TextField("Listen address", text: $bind)
          TextField("HTTPS origin", text: $origin)
          TextField("Certificate PEM path", text: $certificate)
          TextField("Private key PEM path", text: $privateKey)
          Button("Enable Remote Access") {
            perform {
              .status(
                try await client.remoteAccess(
                  "enable",
                  body: [
                    "bind": bind, "origin": origin,
                    "certificate": certificate, "private_key": privateKey,
                  ]))
            }
          }
          .disabled(certificate.isEmpty || privateKey.isEmpty)
        }
      } header: {
        IntegrationSettingsPageTitle("Remote Access")
      } footer: {
        VStack(alignment: .leading, spacing: 8) {
          Text(
            status.enabled
              ? "Remote access is enabled until \(appName) restarts."
              : "Remote access is off. Use a private network or VPN and a certificate trusted by your other computer."
          )
          if let origin = status.origin, let url = URL(string: origin) {
            Link(origin, destination: url)
          }
          Text(capabilities)
          if isWorking { ProgressView().controlSize(.small) }
          if let feedback { Text(feedback).textSelection(.enabled) }
        }
      }
      .disabled(isWorking)

      if status.enabled {
        Section {
          Button("Generate Pairing Code") {
            perform {
              .pairing(try await client.remotePairingCode().code)
            }
          }
          .disabled(isWorking)
        } header: {
          Text("Pair a browser")
        } footer: {
          VStack(alignment: .leading, spacing: 8) {
            Text(
              "Open the HTTPS address on your other computer and enter a single-use code. Pairing expires after five minutes; browser access expires after seven days."
            )
            if let pairingCode, let pairingExpires {
              TimelineView(.periodic(from: .now, by: 1)) { context in
                if context.date < pairingExpires {
                  Text(pairingCode).font(.system(.body, design: .monospaced)).textSelection(
                    .enabled)
                } else {
                  Text("Pairing code expired. Generate another code to connect.")
                }
              }
            }
          }
        }
        if !status.devices.isEmpty {
          Section {
            ForEach(status.devices) { device in
              HStack {
                Text(device.name)
                Spacer()
                Button("Revoke", role: .destructive) {
                  perform {
                    .status(try await client.remoteAccess("revoke", body: ["id": device.id]))
                  }
                }
                .disabled(isWorking)
              }
            }
          } header: {
            Text("Paired browsers")
          } footer: {
            Text("Revocation blocks new requests. Work already submitted may finish on this Mac.")
          }
        }
      }
    }
    .formStyle(.grouped)
    .contentMargins(.vertical, 0, for: .scrollContent)
    .scrollContentBackground(.hidden)
    .background(contentBackground)
    .fritzButtonSize(.regular)
    .task {
      guard refreshesOnAppear else { return }
      while !Task.isCancelled {
        let current = generation
        if !isWorking {
          do {
            let next = try await client.remoteAccess()
            guard !Task.isCancelled else { return }
            if generation == current { status = next }
          } catch {
            if !Task.isCancelled && generation == current { feedback = error.localizedDescription }
          }
        }
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
      }
    }
    .onDisappear {
      generation += 1
      operation?.cancel()
      operation = nil
      isWorking = false
      pairingCode = nil
    }
  }

  private enum Update {
    case status(RemoteAccessStatus)
    case pairing(String)
  }

  private func perform(_ work: @escaping @MainActor () async throws -> Update) {
    generation += 1
    let current = generation
    operation?.cancel()
    isWorking = true
    feedback = nil
    operation = Task { @MainActor in
      defer { if generation == current { isWorking = false } }
      do {
        let update = try await work()
        guard !Task.isCancelled, generation == current else { return }
        switch update {
        case .status(let next):
          status = next
          if !next.enabled { pairingCode = nil }
        case .pairing(let code):
          pairingCode = code
          pairingExpires = Date().addingTimeInterval(300)
        }
      } catch {
        if !Task.isCancelled, generation == current { feedback = error.localizedDescription }
      }
    }
  }
}
