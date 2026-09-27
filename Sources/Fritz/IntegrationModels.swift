import Foundation

public struct WhatsAppGroup: Codable, Identifiable, Equatable, Sendable {
  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
  public let id: String
  public let name: String
}

public struct WhatsAppConnection: Decodable, Equatable, Sendable {
  public init(
    phase: String = "disconnected", saved: Bool = false, enabled: Bool = true, qr: String? = nil,
    expiresAt: TimeInterval? = nil, message: String? = nil, destination: WhatsAppGroup? = nil,
    remoteEnabled: Bool? = nil, remoteEpoch: String? = nil
  ) {
    self.phase = phase
    self.saved = saved
    self.enabled = enabled
    self.qr = qr
    self.expiresAt = expiresAt
    self.message = message
    self.destination = destination
    self.remoteEnabled = remoteEnabled
    self.remoteEpoch = remoteEpoch
  }
  public var phase = "disconnected"
  public var saved = false
  public var enabled = true
  public var qr: String?
  public var expiresAt: TimeInterval?
  public var message: String?
  public var destination: WhatsAppGroup?
  public var remoteEnabled: Bool?
  public var remoteEpoch: String?

  enum CodingKeys: String, CodingKey {
    case phase, saved, enabled, qr, message, destination
    case expiresAt = "expires_at"
    case remoteEnabled = "remote_enabled"
    case remoteEpoch = "remote_epoch"
  }

  public var isConnected: Bool { phase == "connected" }
  public var isPairing: Bool { phase == "pairing" }
  public var isConnecting: Bool { phase == "connecting" }
  public var hasConnection: Bool {
    saved || ["connecting", "pairing", "expired", "error"].contains(phase)
  }
  public var title: String {
    switch phase {
    case "disabled": "Disabled"
    case "connected": "Connected"
    case "connecting": "Connecting…"
    case "pairing": "Scan to connect"
    case "expired": "QR code expired"
    case "error": "Connection needs attention"
    default: "Not connected"
    }
  }
}

public struct WhatsAppConnectionData: Decodable { public let connection: WhatsAppConnection }
public struct WhatsAppGroupsData: Decodable { public let groups: [WhatsAppGroup] }

public struct WhatsAppRemoteCommand: Decodable, Sendable {
  public init(id: String, text: String) {
    self.id = id
    self.text = text
  }
  public let id: String
  public let text: String
}
public struct WhatsAppRemoteClaim: Decodable, Sendable {
  public init(command: WhatsAppRemoteCommand?, epoch: String) {
    self.command = command
    self.epoch = epoch
  }
  public let command: WhatsAppRemoteCommand?
  public let epoch: String
}

public struct RemoteAccessStatus: Decodable, Sendable {
  public init(enabled: Bool = false, origin: String? = nil, devices: [RemoteAccessDevice] = []) {
    self.enabled = enabled
    self.origin = origin
    self.devices = devices
  }
  public var enabled = false
  public var origin: String?
  public var devices: [RemoteAccessDevice] = []
}

public struct RemoteAccessDevice: Decodable, Identifiable, Sendable {
  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
  public let id: String
  public let name: String
}

public struct RemotePairingCode: Decodable, Sendable {
  public init(code: String) { self.code = code }
  public let code: String
}
