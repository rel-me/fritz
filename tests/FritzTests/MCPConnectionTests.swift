import Foundation
import XCTest

@testable import Fritz

@MainActor
final class MCPConnectionTests: XCTestCase {
  func testAcceptsSuccessfulStatusEnvelope() throws {
    try MCPConnection.validate(
      Data(
        #"{"jsonrpc":"2.0","id":1,"result":{"isError":false,"structuredContent":{"status":"ok","data":{}}}}"#
          .utf8))
  }

  func testRejectsProtocolErrorsToolErrorsAndUnrelatedResponses() {
    let responses = [
      #"{"jsonrpc":"2.0","id":1,"error":{"message":"Unsupported protocol"}}"#,
      #"{"jsonrpc":"2.0","id":1,"result":{"isError":true,"content":[{"text":"Agent unavailable"}]}}"#,
      #"{"jsonrpc":"2.0","id":2,"result":{"isError":false,"structuredContent":{"status":"ok"}}}"#,
      #"{"jsonrpc":"2.0","id":1,"result":{}}"#,
      #"{"jsonrpc":"2.0","id":1,"result":{"isError":false,"structuredContent":{"status":"error"}}}"#,
    ]
    for response in responses {
      XCTAssertThrowsError(try MCPConnection.validate(Data(response.utf8)))
    }
  }
}
