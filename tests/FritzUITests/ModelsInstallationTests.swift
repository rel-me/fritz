import XCTest
import Fritz
@testable import FritzUI

final class ModelsInstallationTests: XCTestCase {
    @MainActor func testStorageCancellationDoesNotReportAnError() async {
        var started = false
        var cancelled: [String] = []
        let storage = ModelStorage(events: { _, _, _ in
            started = true
            return AsyncThrowingStream { _ in }
        }, cancel: { cancelled.append($0) })
        let work = Task { await storage.change(to: URL(fileURLWithPath: "/New Models"), previous: "/Models", moveModels: true) }
        for _ in 0..<100 where !started { await Task.yield() }
        XCTAssertTrue(started)
        work.cancel()
        await work.value
        XCTAssertFalse(storage.isBusy)
        XCTAssertNil(storage.error)
        XCTAssertNil(storage.info)
        XCTAssertFalse(cancelled.isEmpty)
    }

    func testDownloadRequiresMatchingTerminalResultBeforeInstallation() throws {
        func state(_ json: String, installing: Bool = true) throws -> LocalModelInstallState {
            try JSONDecoder().decode(LocalModelEvent.self, from: Data(json.utf8)).state(for: "test", installing: installing)
        }
        XCTAssertEqual(try state(#"{"type":"progress","status":"downloading","downloaded":4,"total":10}"#), .downloading(downloaded: 4, total: 10))
        XCTAssertEqual(try state(#"{"type":"progress","status":"ready","downloaded":10,"total":10}"#), .checking)
        XCTAssertEqual(try state(#"{"type":"result","result":{"modelId":"test","installed":true}}"#), .installed)
        XCTAssertEqual(try state(#"{"type":"result","result":{"models":[{"id":"test","installed":false,"directory":"/Models"}]}}"#, installing: false), .available)
        XCTAssertThrowsError(try state(#"{"type":"result","result":{"modelId":"other","installed":true}}"#))
        XCTAssertThrowsError(try state(#"{"type":"progress","status":"ready","downloaded":2,"total":10}"#))
        XCTAssertThrowsError(try state(#"{"type":"progress","status":"downloading","downloaded":11,"total":10}"#))
        XCTAssertThrowsError(try state(#"{"type":"progress","status":"downloading","downloaded":0,"total":0}"#))
    }
}
