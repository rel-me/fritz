import AppKit
import XCTest
@testable import Bonsplit

@MainActor
final class TabHoverTrackingTests: XCTestCase {
    func testTrackingDoesNotInterceptTabSelectionOrCloseClicks() {
        let view = TabHoverTrackingNSView(frame: NSRect(x: 0, y: 0, width: 140, height: 35))
        XCTAssertNil(view.hitTest(NSPoint(x: 40, y: 15)))
        XCTAssertNil(view.hitTest(NSPoint(x: 125, y: 15)))
        view.updateTrackingAreas()
        XCTAssertEqual(view.trackingAreas.count, 1)
        view.updateTrackingAreas()
        XCTAssertEqual(view.trackingAreas.count, 1)
    }

    func testHoverCoversReservedCloseSpaceAndClearsOutsideTab() async {
        let view = TabHoverTrackingNSView(frame: NSRect(x: 0, y: 0, width: 140, height: 35))
        defer { withExtendedLifetime(view) {} }
        var changes: [Bool] = []
        view.onChange = { changes.append($0) }
        view.updateHover(at: NSPoint(x: 125, y: 15))
        await drainHoverUpdates()
        XCTAssertEqual(changes, [true])
        view.updateHover(at: NSPoint(x: 40, y: 15))
        await drainHoverUpdates()
        XCTAssertEqual(changes, [true])
        view.updateHover(at: NSPoint(x: 141, y: 15))
        await drainHoverUpdates()
        XCTAssertEqual(changes, [true, false])
    }

    func testPendingEntryCannotRestoreHoverAfterExit() async {
        let view = TabHoverTrackingNSView(frame: NSRect(x: 0, y: 0, width: 140, height: 35))
        defer { withExtendedLifetime(view) {} }
        var changes: [Bool] = []
        view.onChange = { changes.append($0) }
        view.updateHover(at: NSPoint(x: 50, y: 15))
        view.updateHover(at: nil)
        await drainHoverUpdates()
        XCTAssertEqual(changes, [false])
    }

    private func drainHoverUpdates() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
