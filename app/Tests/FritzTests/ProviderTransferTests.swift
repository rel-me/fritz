import Foundation
import Fritz
import XCTest
@testable import FritzApp

final class ProviderTransferTests: XCTestCase {
    func testRELImportAndFritzExportKeepServiceEndpointAndModelWithoutIdentityOrDefault() throws {
        let text = #"{"format":"rel.providers","version":1,"configuration":[{"name":"Fireworks","baseURL":"https://api.fireworks.ai/inference/v1","modelID":"sample","maxTurns":24},{"name":"TypeSafe AI","modelID":"jev-latest","maxTurns":24}]}"#
        let configurations = try ProviderConfigurationTransfer.decode(text)
        let items = try ProviderConfigurationTransfer.plan(configurations, existing: [], policy: .skip)
        XCTAssertEqual(items.map(\.connection.provider), [.openAICompatible, .jev])
        XCTAssertEqual(items[1].connection.providerDisplayName, "TypeSafe")
        let exported = try ProviderConfigurationTransfer.export(items.map { .init($0.connection) })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(exported.utf8)) as? [String: Any])
        XCTAssertEqual(object["format"] as? String, "fritz.providers")
        let records = try XCTUnwrap(object["configuration"] as? [[String: Any]])
        XCTAssertEqual(records[0]["baseURL"] as? String, "https://api.fireworks.ai/inference/v1")
        XCTAssertEqual(records[0]["modelID"] as? String, "sample")
        XCTAssertEqual(records[1]["name"] as? String, "TypeSafe")
        XCTAssertNil(records[0]["id"])
        XCTAssertNil(records[0]["apiKey"])
        XCTAssertNil(object["defaultConnectionId"])
        let single = try ProviderConfigurationTransfer.export([.init(items[0].connection, apiKey: "synthetic-key")])
        XCTAssertEqual(try ProviderConfigurationTransfer.decode(single).first?.apiKey, "synthetic-key")
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
}
