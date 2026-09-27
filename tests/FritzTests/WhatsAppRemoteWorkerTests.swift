import Foundation
import XCTest

@testable import Fritz

final class WhatsAppRemoteWorkerTests: XCTestCase {
  @MainActor
  func testRevocationAndStatusFailureCancelExecutionWithoutReply() async throws {
    for failsStatus in [false, true] {
      let client = RemoteClientFixture(failsStatus: failsStatus)
      let cancelled = expectation(description: "Execution cancelled")
      let controller = WhatsAppRemoteWorker(
        client: client, invalidate: {}, formatReply: { $0 },
        waitForPoll: { try await Task.sleep(for: .milliseconds(1)) })
      controller.start { _ in
        await client.markExecuting()
        do { try await Task.sleep(for: .seconds(60)) } catch {
          cancelled.fulfill()
          throw error
        }
        return "Must never send"
      }
      await fulfillment(of: [cancelled], timeout: 2)
      controller.stop()
      let replies = await client.replies
      XCTAssertEqual(replies, 0)
    }
  }

}

private actor RemoteClientFixture: WhatsAppRemoteClient {
  let failsStatus: Bool
  var snapshots = 0
  var claimed = false
  var executing = false
  var started: CheckedContinuation<Void, Never>?
  private(set) var replies = 0

  init(failsStatus: Bool) { self.failsStatus = failsStatus }
  func markExecuting() {
    executing = true
    started?.resume()
    started = nil
  }
  func whatsAppConnection() async throws -> WhatsAppConnection {
    snapshots += 1
    if snapshots > 1 {
      if !executing { await withCheckedContinuation { started = $0 } }
      if failsStatus { throw URLError(.networkConnectionLost) }
      return WhatsAppConnection(phase: "connected", remoteEnabled: false, remoteEpoch: "revoked")
    }
    return WhatsAppConnection(phase: "connected", remoteEnabled: true, remoteEpoch: "initial")
  }
  func claimWhatsAppCommand() async throws -> WhatsAppRemoteClaim {
    defer { claimed = true }
    return WhatsAppRemoteClaim(
      command: claimed ? nil : WhatsAppRemoteCommand(id: "command", text: "ask test"),
      epoch: "initial")
  }
  func replyToWhatsAppCommand(id: String, epoch: String, text: String) async throws { replies += 1 }
}
