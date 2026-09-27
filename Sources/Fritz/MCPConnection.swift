import Foundation

@MainActor
public struct MCPConnection {
  public let executableURL: URL
  private let serverName: String
  private let environment: [String: String]
  private let processEnvironment: [String: String]
  private let statusTool: String
  private let clientName: String
  private let preflight: @MainActor () async throws -> Void
  public init(
    executableURL: URL, serverName: String, environment: [String: String],
    processEnvironment: [String: String], statusTool: String, clientName: String,
    preflight: @escaping @MainActor () async throws -> Void
  ) {
    self.executableURL = executableURL
    self.serverName = serverName
    self.environment = environment
    self.processEnvironment = processEnvironment
    self.statusTool = statusTool
    self.clientName = clientName
    self.preflight = preflight
  }

  public func configuration() throws -> String {
    let configuration = [
      "mcpServers": [
        serverName: [
          "command": executableURL.path,
          "args": [String](),
          "env": environment,
        ] as [String: Any]
      ]
    ]
    let data = try JSONSerialization.data(
      withJSONObject: configuration,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    return String(decoding: data, as: UTF8.self)
  }

  public func test() async throws {
    // Check this runtime before the adapter can attempt to launch its owning app.
    try await preflight()
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let outputURL = directory.appendingPathComponent("response")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close() }
    let input = Pipe()
    let process = Process()
    process.executableURL = executableURL
    process.environment = processEnvironment
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
      try? input.fileHandleForWriting.close()
      if process.isRunning { process.terminate() }
    }
    let request: [String: Any] = [
      "jsonrpc": "2.0", "id": 1, "method": "tools/call",
      "params": [
        "name": statusTool, "arguments": [String: String](),
        "_meta": [
          "io.modelcontextprotocol/protocolVersion": "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities": [String: String](),
          "io.modelcontextprotocol/clientInfo": ["name": clientName, "version": "1"],
        ],
      ],
    ]
    var data = try JSONSerialization.data(withJSONObject: request)
    data.append(0x0A)
    try input.fileHandleForWriting.write(contentsOf: data)
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      try Task.checkCancellation()
      let response = try Data(contentsOf: outputURL)
      if response.contains(0x0A) {
        try Self.validate(response)
        return
      }
      guard process.isRunning else {
        throw ConnectionError.failed("MCP adapter exited before responding.")
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw ConnectionError.failed("MCP connection timed out. Try again.")
  }

  public static func validate(_ data: Data) throws {
    guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      response["jsonrpc"] as? String == "2.0",
      response["id"] as? Int == 1
    else {
      throw ConnectionError.failed("MCP adapter returned an invalid response.")
    }
    if let error = response["error"] as? [String: Any] {
      throw ConnectionError.failed(error["message"] as? String ?? "MCP request failed.")
    }
    guard let result = response["result"] as? [String: Any],
      result["isError"] as? Bool == false,
      let envelope = result["structuredContent"] as? [String: Any],
      envelope["status"] as? String == "ok"
    else {
      let result = response["result"] as? [String: Any]
      let content = result?["content"] as? [[String: Any]]
      throw ConnectionError.failed(content?.first?["text"] as? String ?? "MCP connection failed.")
    }
  }

  public enum ConnectionError: LocalizedError {
    case failed(String)
    public var errorDescription: String? {
      switch self {
      case .failed(let message): message
      }
    }
  }
}
