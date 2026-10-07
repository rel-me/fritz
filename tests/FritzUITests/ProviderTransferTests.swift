import Foundation
import Fritz
import XCTest
@testable import FritzUI

final class ProviderTransferTests: XCTestCase {
    func testImportsCURLChecksAndPlansSkipOrOverwriteByService() throws {
        let text = """
        curl --request GET 'https://api.fireworks.ai/inference/v1/models' \\
          --header 'Authorization: Bearer synthetic-key'
        curl 'https://api.typesafe.ai/v1/models' -H 'Authorization: Bearer decision-key'
        """
        let configurations = try ProviderConfigurationTransfer.decode(text)
        let items = try ProviderConfigurationTransfer.plan(configurations, existing: [], policy: .skip)
        XCTAssertEqual(items.map(\.connection.provider), [.openAICompatible, .jev])
        XCTAssertEqual(items[0].connection.baseURL, "https://api.fireworks.ai/inference/v1")
        XCTAssertEqual(items[0].connection.name, "Fireworks")
        XCTAssertEqual(items[0].apiKey, "synthetic-key")
        XCTAssertNil(items[1].connection.baseURL)
        XCTAssertEqual(items[1].connection.modelID, "jev-latest")
        XCTAssertEqual(items[1].apiKey, "decision-key")

        let existing = ProviderConnection(name: "My custom name", provider: .openAICompatible,
                                          baseURL: "https://api.fireworks.ai/inference/v1", modelID: "old")
        let keyless = try ProviderConfigurationTransfer.decode("curl 'https://api.fireworks.ai/inference/v1/models'")
        XCTAssertTrue(try ProviderConfigurationTransfer.plan(keyless, existing: [existing], policy: .skip).isEmpty)
        let imported = try XCTUnwrap(ProviderConfigurationTransfer.plan(keyless, existing: [existing], policy: .overwrite).first)
        XCTAssertEqual(imported.connection.id, existing.id)
        XCTAssertEqual(imported.connection.name, "My custom name")
        XCTAssertNil(imported.apiKey)
        let duplicate = ProviderConnection(name: "Other", provider: existing.provider, baseURL: existing.baseURL)
        XCTAssertThrowsError(try ProviderConfigurationTransfer.plan(keyless, existing: [existing, duplicate], policy: .overwrite))
    }

    func testImportsQuotedHeadersLocalHealthAndPlaceholderKeys() throws {
        let examples: [(String, AIProviderKind, String, String?)] = [
            (#"curl -H 'x-api-key: quoted"key' -H 'anthropic-version: 2023-06-01' https://api.anthropic.com/v1/models"#,
             .anthropic, "https://api.anthropic.com/v1", "quoted\"key"),
            (#"curl --url "https://generativelanguage.googleapis.com/v1beta/models" --header "x-goog-api-key: YOUR_API_KEY""#,
             .gemini, "https://generativelanguage.googleapis.com/v1beta", nil),
            ("curl http://localhost:11434/api/tags", .ollama, "http://localhost:11434", nil),
            ("curl -X GET http://127.0.0.1:1234/v1/health", .openAICompatible, "http://127.0.0.1:1234/v1", nil),
        ]
        for (text, provider, base, key) in examples {
            let imported = try XCTUnwrap(ProviderConfigurationTransfer.decode(text).first)
            XCTAssertEqual(imported.connection.provider, provider)
            XCTAssertEqual(imported.connection.baseURL, base)
            XCTAssertEqual(imported.apiKey, key)
        }
    }

    func testRejectsJSONShellExecutionFilesAndUnsupportedRequests() throws {
        let valid = "curl https://api.openai.com/v1/models"
        for text in [
            "{", #"{"format":"fritz.provider","version":1,"configuration":{"name":"OpenAI"}}"#,
            String(repeating: " ", count: ProviderConfigurationTransfer.maximumBytes + 1),
            valid + "; touch /tmp/should-not-run", valid + "\nwhoami", valid + " | sh",
            valid + " -H \"Authorization: Bearer $(whoami)\"", valid + " -H `whoami`",
            valid + " --config /tmp/key", valid + " --header @/tmp/key", valid + " --data @/tmp/body",
            valid + " -X POST", valid + " --insecure", valid + " -H 'X-Custom-Auth: key'",
            "curl http://remote.example/v1/models", "curl https://user:key@api.openai.com/v1/models",
            "curl https://api.openai.com/v1/models?key=secret", "curl https://api.openai.com/v1/responses",
            "curl --config - <<'CURL_CONFIG'\nurl = \"https://api.openai.com/v1/models\"",
        ] {
            XCTAssertThrowsError(try ProviderConfigurationTransfer.decode(text), text)
        }
    }

    func testCURLExportsSendProviderRequestsWithoutShellExpansion() throws {
        let sentinel = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sentinel) }
        let special = "quoted'\"\\$(touch \(sentinel.path))"
        let cases: [(AIProviderKind, String, String?, Bool)] = [
            (.openAI, "/models", "Authorization", true),
            (.openAICompatible, "/models", "Authorization", true),
            (.openRouter, "/models", "Authorization", true),
            (.anthropic, "/models", "x-api-key", true),
            (.gemini, "/models", "x-goog-api-key", true),
            (.ollama, "/api/tags", "Authorization", true),
            (.jev, "/models", "Authorization", true),
            (.openAI, "/models", "Authorization", false),
            (.ollama, "/api/tags", nil, false),
            (.openAICompatible, "/models", nil, false),
        ]
        for (provider, suffix, header, includesKey) in cases {
            let server = Process()
            server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            server.arguments = ["python3", "-u", "-c", """
            import json
            from http.server import BaseHTTPRequestHandler, HTTPServer
            class Capture(BaseHTTPRequestHandler):
                def log_message(self, *_): pass
                def do_GET(self):
                    print(json.dumps({'path': self.path, 'headers': dict(self.headers)}), flush=True)
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b'{"data":[{"id":"check-model"}]}')
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
            let model = includesKey ? special : ""
            let connection = ProviderConnection(name: special, provider: provider,
                                                baseURL: "http://127.0.0.1:\(port)/v1" + (provider == .jev ? "/systemone" : ""), modelID: model)
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
            XCTAssertNil(headers["Content-Length"])
            if provider == .anthropic { XCTAssertEqual(headers["anthropic-version"], "2023-06-01") }
            if provider != .jev {
                let imported = try XCTUnwrap(ProviderConfigurationTransfer.decode(command).first)
                XCTAssertEqual(imported.connection.name, special)
                XCTAssertEqual(imported.connection.provider, provider)
                XCTAssertEqual(imported.connection.baseURL, "http://127.0.0.1:\(port)/v1")
                XCTAssertEqual(imported.connection.modelID, model)
                XCTAssertEqual(imported.apiKey, includesKey ? special : nil)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        }
    }

    func testMultiProviderExportsRoundTripWithFixedDecisionEndpoint() throws {
        let connections = [
            ProviderConnection(name: "Decisions", provider: .jev, modelID: "jev-latest"),
            ProviderConnection(name: "OpenAI Decisions", provider: .openAIDecisions, modelID: "gpt-6-luna"),
            ProviderConnection(name: "Local chat", provider: .ollama, baseURL: "http://localhost:11434", modelID: "sample"),
        ]
        let text = try ProviderConfigurationTransfer.exportCURL(connections.map { .init($0) })
        let items = try ProviderConfigurationTransfer.plan(ProviderConfigurationTransfer.decode(text), existing: [], policy: .overwrite)
        XCTAssertEqual(items.map(\.connection.name), ["Decisions", "OpenAI Decisions", "Local chat"])
        XCTAssertEqual(items.map(\.connection.provider), [.jev, .openAIDecisions, .ollama])
        XCTAssertEqual(items.map(\.connection.modelID), ["jev-latest", "gpt-6-luna", "sample"])
        XCTAssertNil(items[0].connection.baseURL)
        XCTAssertNil(items[0].apiKey)
        XCTAssertNil(items[1].apiKey)
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
