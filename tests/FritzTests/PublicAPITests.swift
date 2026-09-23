import Foundation
import Fritz
import FritzUpdates
import XCTest

/// Intentionally no @testable import: these APIs must work for a separate host app.
final class PublicAPITests: XCTestCase {
    func testCatalogResourceAndProviderWireFormatAreAvailableOutsideTheApp() throws {
        let model = try XCTUnwrap(NativeModelDescriptor.catalog.first)
        let connection = ProviderConnection(name: "Library fixture", provider: .fritz, modelID: model.id)
        let encoded = try JSONEncoder().encode(ProviderRegistry(connections: [connection]))
        let decoded = try JSONDecoder().decode(ProviderRegistry.self, from: encoded)
        XCTAssertEqual(decoded.connections, [connection])
        XCTAssertEqual(ChatModelOption(connection: connection, model: model.model).modelID, model.id)
        XCTAssertTrue(model.licenseURL.scheme == "https")
    }

    func testInstallerUsesHostExecutableName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("rel")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let result = CommandLineInstaller(environment: ["PATH": bin.path], cliURL: executable).install()
        XCTAssertEqual(result, .installed(bin.appendingPathComponent("rel")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bin.appendingPathComponent("fritz").path))
    }

    @MainActor
    func testAgentUsesHostExecutableAndSupportsRestartAndCancellation() async throws {
        let script = #"""
        import json, sys
        for line in sys.stdin:
            r = json.loads(line)
            if r['method'] == 'health':
                print(json.dumps({'id': r['id'], 'type': 'result', 'result': {'host': 'fixture'}}), flush=True)
        """#
        let client = AgentClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", script], environment: ["PATH": "/usr/bin:/bin"])
        defer { client.stop() }
        struct Health: Decodable { let host: String }
        client.start()
        XCTAssertTrue(client.isRunning)
        let health: Health = try await client.request("health")
        XCTAssertEqual(health.host, "fixture")
        let stream = client.stream(method: "wait", id: "cancel-fixture")
        client.cancel("cancel-fixture")
        do {
            for try await _ in stream { XCTFail("Unexpected event") }
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { throw error }
        client.restart()
        let restarted: Health = try await client.request("health")
        XCTAssertEqual(restarted.host, "fixture")
        client.stop()
        XCTAssertFalse(client.isRunning)
    }
}
