import AppKit
import SwiftUI
import XCTest
@testable import FritzApp

@MainActor final class MarkupPanelTests: XCTestCase {
    // Package tests cannot cover the app view's loader-to-session observation.
    // Never apply or refresh the session manually in this mounted workflow.
    func testMountedPanelAppliesFileEditsAndRetainsNoteAcrossReloadErrors() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fritz-markup-panel-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Panel.xml")
        let store = MarkupPanelStore()
        defer { store.stop() }
        store.note = "Keep my scratch note"

        _ = NSApplication.shared
        let bounds = NSRect(x: 0, y: 0, width: 260, height: 480)
        let host = NSHostingView(rootView: WorkspaceRightPanel(store: store, close: {}))
        host.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }

        func settleNativeUpdates() {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }

        func eventually(_ condition: () -> Bool) async throws -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            repeat {
                settleNativeUpdates()
                if condition() { return true }
                try await Task.sleep(for: .milliseconds(25))
            } while clock.now < deadline
            return condition()
        }

        func writeDocument(_ id: String) throws {
            let source = """
                <Interface version="1">
                  <VStack id="\(id)">
                    <TextField id="note" title="Note" text="$note"/>
                  </VStack>
                </Interface>
                """
            try Data(source.utf8).write(to: file, options: .atomic)
        }

        settleNativeUpdates()
        try writeDocument("first")
        await store.loader.open(file)
        let opened = try await eventually { store.session.document?.root.id == "first" }
        XCTAssertTrue(opened, "The mounted panel must install the selected file.")
        guard opened else { return }

        // The second save requires source-change observation even if initial
        // presentation happened to coincide with the view's onAppear callback.
        try writeDocument("edited")
        let edited = try await eventually { store.session.document?.root.id == "edited" }
        XCTAssertTrue(edited, "Saving the file must replace the mounted session document.")
        guard edited else { return }

        try Data(#"<Interface version="1"><Missing id="invalid"/></Interface>"#.utf8)
            .write(to: file, options: .atomic)
        let rejected = try await eventually { store.session.diagnostic != nil }
        XCTAssertTrue(rejected, "Invalid markup must reach the panel's session diagnostic.")
        guard rejected else { return }
        XCTAssertNil(store.loader.diagnostic)
        XCTAssertEqual(store.session.document?.root.id, "edited")
        XCTAssertEqual(store.note, "Keep my scratch note")

        try writeDocument("recovered")
        let recovered = try await eventually {
            store.session.document?.root.id == "recovered" && store.diagnostic == nil
        }
        XCTAssertTrue(recovered, "A repaired file must clear the error and install its document.")
        XCTAssertEqual(store.note, "Keep my scratch note")
    }
}
