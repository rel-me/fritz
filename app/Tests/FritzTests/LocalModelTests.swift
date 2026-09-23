import XCTest
import Fritz
import FritzUpdates
@testable import FritzApp

final class LocalModelTests: XCTestCase {
    func testBundledCatalogAndFritzProvider() throws {
        let catalog = NativeModelDescriptor.catalog
        XCTAssertFalse(catalog.isEmpty)
        XCTAssertEqual(Set(catalog.map(\.id)).count, catalog.count)
        XCTAssertTrue(catalog.contains { $0.id == "qwen2.5-1.5b-instruct-q4_k_m" })
        XCTAssertTrue(catalog.allSatisfy { $0.size > 0 && $0.memoryGB > 0 && $0.licenseURL.scheme == "https" })
        XCTAssertTrue(AIProviderCategory.local.contains(.adapter(.fritz)))
        XCTAssertFalse(AIProviderCategory.remote.contains(.adapter(.fritz)))
        XCTAssertFalse(AIProviderKind.fritz.requiresAPIKey)
        let connection = ProviderConnection(name: "Fritz", provider: .fritz, modelID: catalog[0].id)
        XCTAssertEqual(try connection.jsonObject()["provider"] as? String, "fritz")
        XCTAssertEqual(connection.providerDisplayName, "Fritz")
    }

    func testDownloadRequiresMatchingTerminalResultBeforeInstallation() throws {
        func state(_ json: String, installing: Bool = true) throws -> NativeModelInstallState {
            try JSONDecoder().decode(LocalModelEvent.self, from: Data(json.utf8)).state(for: "test", installing: installing)
        }
        XCTAssertEqual(try state(#"{"type":"progress","status":"downloading","downloaded":4,"total":10}"#), .downloading(downloaded: 4, total: 10))
        XCTAssertEqual(try state(#"{"type":"progress","status":"ready","downloaded":10,"total":10}"#), .checking)
        XCTAssertEqual(try state(#"{"type":"result","result":{"modelId":"test","installed":true}}"#), .installed)
        XCTAssertEqual(try state(#"{"type":"result","result":{"models":[{"id":"test","installed":false}]}}"#, installing: false), .available)
        XCTAssertThrowsError(try state(#"{"type":"result","result":{"modelId":"other","installed":true}}"#))
        XCTAssertThrowsError(try state(#"{"type":"progress","status":"ready","downloaded":2,"total":10}"#))
        XCTAssertThrowsError(try state(#"{"type":"progress","status":"downloading","downloaded":11,"total":10}"#))
        XCTAssertThrowsError(try state(#"{"type":"progress","status":"downloading","downloaded":0,"total":0}"#))
    }
}
