import Foundation
import Fritz
import XCTest
@testable import FritzApp

final class ProviderTransferTests: XCTestCase {
    func testImportedConfigurationsKeepServiceEndpointModelAndKeys() throws {
        let text = #"{"format":"rel.providers","version":1,"configuration":[{"name":"Fireworks","baseURL":"https://api.fireworks.ai/inference/v1","modelID":"sample","apiKey":"synthetic-key","maxTurns":24},{"name":"TypeSafe AI","modelID":"jev-latest","maxTurns":24}]}"#
        let configurations = try ProviderConfigurationTransfer.decode(text)
        let items = try ProviderConfigurationTransfer.plan(configurations, existing: [], policy: .skip)
        XCTAssertEqual(items.map(\.connection.provider), [.openAICompatible, .jev])
        XCTAssertEqual(items[0].connection.baseURL, "https://api.fireworks.ai/inference/v1")
        XCTAssertEqual(items[0].connection.modelID, "sample")
        XCTAssertEqual(items[0].apiKey, "synthetic-key")
        XCTAssertEqual(items[1].connection.providerDisplayName, "TypeSafe")
        XCTAssertEqual(items[1].connection.modelID, "jev-latest")
    }

    func testSkipAndOverwriteMatchServiceAndPreserveExistingIdentity() throws {
        let existing = ProviderConnection(name: "My custom name", provider: .openAICompatible,
                                          baseURL: "https://api.fireworks.ai/inference/v1", modelID: "old")
        let text = #"{"format":"fritz.provider","version":1,"configuration":{"name":"Fireworks","baseURL":"https://api.fireworks.ai/inference/v1","modelID":"new"}}"#
        let configurations = try ProviderConfigurationTransfer.decode(text)
        XCTAssertTrue(try ProviderConfigurationTransfer.plan(configurations, existing: [existing], policy: .skip).isEmpty)
        let imported = try XCTUnwrap(ProviderConfigurationTransfer.plan(configurations, existing: [existing], policy: .overwrite).first)
        XCTAssertEqual(imported.connection.id, existing.id)
        XCTAssertEqual(imported.connection.name, "My custom name")
        XCTAssertEqual(imported.connection.modelID, "new")
        XCTAssertNil(imported.apiKey)
        let duplicate = ProviderConnection(name: "Other", provider: existing.provider, baseURL: existing.baseURL)
        XCTAssertThrowsError(try ProviderConfigurationTransfer.plan(configurations, existing: [existing, duplicate], policy: .overwrite))
    }

    func testRejectsMalformedUnsupportedAndOversizeTransfers() {
        for text in [
            "{", String(repeating: " ", count: ProviderConfigurationTransfer.maximumBytes + 1),
            #"{"format":"fritz.providers","version":1,"configuration":[]}"#,
            #"{"format":"fritz.provider","version":2,"configuration":{"name":"OpenAI"}}"#,
            #"{"format":"rel.profile","version":1,"configuration":{"name":"OpenAI"}}"#,
            #"{"format":"rel.provider","version":1,"configuration":{"name":"REL"}}"#,
            #"{"format":"fritz.provider","version":1,"configuration":{"name":"Fireworks","baseURL":"https://example.com/v1"}}"#,
        ] {
            XCTAssertThrowsError(try ProviderConfigurationTransfer.decode(text))
        }
    }

    func testCURLExportsSendProviderRequestsWithoutShellExpansion() throws {
        let sentinel = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sentinel) }
        let special = "quoted'\"\\$(touch \(sentinel.path))"
        let cases: [(AIProviderKind, String, String?, Bool)] = [
            (.openAI, "/responses", "Authorization", true),
            (.openAICompatible, "/chat/completions", "Authorization", true),
            (.openRouter, "/chat/completions", "Authorization", true),
            (.anthropic, "/messages", "x-api-key", true),
            (.gemini, "/models/sample:generateContent", "x-goog-api-key", true),
            (.ollama, "/api/chat", "Authorization", true),
            (.jev, "", "Authorization", true),
            (.openAI, "/responses", "Authorization", false),
            (.ollama, "/api/chat", nil, false),
        ]
        for (provider, suffix, header, includesKey) in cases {
            let server = Process()
            server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            server.arguments = ["python3", "-u", "-c", """
            import json
            from http.server import BaseHTTPRequestHandler, HTTPServer
            class Capture(BaseHTTPRequestHandler):
                def log_message(self, *_): pass
                def do_POST(self):
                    body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                    print(json.dumps({'path': self.path, 'headers': dict(self.headers), 'body': body}), flush=True)
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b'{}')
            server = HTTPServer(('127.0.0.1', 0), Capture)
            server.timeout = 5
            print(server.server_port, flush=True)
            server.handle_request()
            server.server_close()
            """]
            let receipt = Pipe()
            server.standardOutput = receipt
            server.standardError = FileHandle.nullDevice
            try server.run()
            defer { if server.isRunning { server.terminate() }; server.waitUntilExit() }
            let port = try readLine(receipt.fileHandleForReading)
            let model = provider == .gemini ? "sample" : includesKey ? special : "MODEL_ID"
            let connection = ProviderConnection(name: provider.name, provider: provider,
                                                baseURL: "http://127.0.0.1:\(port)/v1", modelID: includesKey ? model : "")
            let command = try ProviderConfigurationTransfer.exportCURL([.init(connection, apiKey: includesKey ? special : nil)])
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            let input = Pipe()
            shell.standardInput = input
            shell.standardOutput = FileHandle.nullDevice
            shell.standardError = FileHandle.nullDevice
            try shell.run()
            try input.fileHandleForWriting.write(contentsOf: Data(command.utf8))
            try input.fileHandleForWriting.close()
            shell.waitUntilExit()
            XCTAssertEqual(shell.terminationStatus, 0, provider.rawValue)
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(readLine(receipt.fileHandleForReading).utf8)) as? [String: Any])
            XCTAssertEqual(response["path"] as? String, "/v1" + suffix)
            let headers = try XCTUnwrap(response["headers"] as? [String: String])
            if let header {
                XCTAssertEqual(headers[header], (header == "Authorization" ? "Bearer " : "") + (includesKey ? special : "YOUR_API_KEY"))
            } else {
                XCTAssertNil(headers["Authorization"])
            }
            XCTAssertEqual(headers["Content-Type"], "application/json")
            let body = try XCTUnwrap(response["body"] as? [String: Any])
            switch provider {
            case .gemini:
                let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
                XCTAssertEqual((contents[0]["parts"] as? [[String: String]])?.first?["text"], "Hello")
            case .jev:
                XCTAssertEqual(body["model"] as? String, model)
                XCTAssertEqual((body["state"] as? [String: String])?["message"], "Remind me tomorrow")
                XCTAssertNotNil((body["questions"] as? [String: Any])?["reminder"])
            default:
                XCTAssertEqual(body["model"] as? String, model)
                let messages = try XCTUnwrap(body[provider == .openAI ? "input" : "messages"] as? [[String: String]])
                XCTAssertEqual(messages, [["role": "user", "content": "Hello"]])
                if provider == .anthropic {
                    XCTAssertEqual(headers["anthropic-version"], "2023-06-01")
                    XCTAssertEqual(body["max_tokens"] as? Int, 1024)
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        }
    }

    func testCURLRejectsNativeConnectionsWithoutHTTPEndpoints() throws {
        for provider in [AIProviderKind.fritz, .ollaya] {
            let configuration = ProviderConfigurationTransfer.Configuration(
                ProviderConnection(name: provider.name, provider: provider, modelID: "local-model"))
            XCTAssertThrowsError(try ProviderConfigurationTransfer.exportCURL([configuration]))
        }
    }

    private func readLine(_ handle: FileHandle) throws -> String {
        var data = Data()
        while let byte = try handle.read(upToCount: 1), !byte.isEmpty {
            if byte[0] == 10 { break }
            data.append(byte)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
