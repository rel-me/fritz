import Foundation

/// An authenticated host transport returning the decoded success payload as JSON.
/// Hosts keep their own endpoint, credentials, and RPC error validation.
public protocol IntegrationTransport: Sendable {
  func integrationRequest(path: String, method: String, body: Data?) async throws -> Data
}

public struct IntegrationClient: Sendable {
  private let transport: any IntegrationTransport
  public init(transport: any IntegrationTransport) { self.transport = transport }
  private func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil)
    async throws -> T
  {
    let data = try await transport.integrationRequest(path: path, method: method, body: body)
    return try JSONDecoder().decode(T.self, from: data)
  }
  private func json<T: Encodable>(_ body: T) throws -> Data { try JSONEncoder().encode(body) }
  public func remoteAccess(_ operation: String? = nil, body: [String: String] = [:]) async throws
    -> RemoteAccessStatus
  {
    try await request(
      "remote-access" + (operation.map { "/" + $0 } ?? ""),
      method: operation == nil ? "GET" : "POST", body: operation == nil ? nil : json(body))
  }
  public func remotePairingCode() async throws -> RemotePairingCode {
    try await request("remote-access/pair", method: "POST", body: Data("{}".utf8))
  }
  public func whatsAppConnection() async throws -> WhatsAppConnection {
    let response: WhatsAppConnectionData = try await request("whatsapp")
    return response.connection
  }
  private func connection(_ path: String, method: String = "POST", body: Data? = nil) async throws
    -> WhatsAppConnection
  {
    let response: WhatsAppConnectionData = try await request(
      "whatsapp/" + path, method: method, body: body)
    return response.connection
  }
  public func connectWhatsApp() async throws -> WhatsAppConnection {
    try await connection("connect", body: Data("{}".utf8))
  }
  public func setWhatsAppEnabled(_ enabled: Bool) async throws -> WhatsAppConnection {
    try await connection("enabled", body: json(["enabled": enabled]))
  }
  public func removeWhatsAppConnection() async throws -> WhatsAppConnection {
    try await connection("connection", method: "DELETE")
  }
  public func whatsAppGroups() async throws -> [WhatsAppGroup] {
    let response: WhatsAppGroupsData = try await request("whatsapp/groups")
    return response.groups
  }
  public func selectWhatsAppGroup(_ id: String) async throws -> WhatsAppConnection {
    try await connection("destination", body: json(["id": id]))
  }
  public func setWhatsAppRemoteEnabled(_ enabled: Bool) async throws -> WhatsAppConnection {
    try await connection("remote/enabled", body: json(["enabled": enabled]))
  }
  public func claimWhatsAppCommand() async throws -> WhatsAppRemoteClaim {
    try await request("whatsapp/remote/claim", method: "POST", body: Data("{}".utf8))
  }
  public func replyToWhatsAppCommand(id: String, epoch: String, text: String) async throws {
    _ = try await transport.integrationRequest(
      path: "whatsapp/remote/reply", method: "POST",
      body: json(["id": id, "epoch": epoch, "text": text]))
  }
  public func sendWhatsApp(text: String) async throws {
    _ = try await transport.integrationRequest(
      path: "whatsapp/send", method: "POST", body: json(["text": text]))
  }
}
