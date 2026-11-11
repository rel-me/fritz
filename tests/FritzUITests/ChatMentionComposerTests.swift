import AppKit
import Fritz
import FritzUI
import SwiftUI
import XCTest

@MainActor
final class ChatMentionComposerTests: XCTestCase {
    @MainActor @Observable final class State {
        var draft = ChatMentionDraft()
        var sends = 0
        let registry = ChatMentionRegistry()
    }

    private struct Fixture: View {
        @Bindable var state: State
        @FocusState private var focused: Bool
        var body: some View {
            ChatComposer(mentions: $state.draft, registry: state.registry,
                         placeholder: "Message", canSend: true, isResponding: false,
                         isFocused: $focused, send: { state.sends += 1 }, stop: {}) {
                EmptyView()
            }
            .padding()
            .onAppear { focused = true }
        }
    }

    func testNativeSelectionInsertsIdentityBeforeReturnSends() throws {
        let state = State()
        let reddit = ChatMentionItem(id: .init(source: "profiles", value: "reddit"),
                                    name: "Reddit", kind: .entity)
        try state.registry.register(source: "profiles", items: [reddit,
            .init(id: .init(source: "profiles", value: "oxylabs"), name: "Oxylabs", kind: .entity)
        ])
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        // SwiftPM starts as a command-line process (.prohibited), which cannot
        // reliably own a key window. Permit the fixture's UI without activating
        // the app or adding a Dock icon, and restore the runner's policy afterward.
        try XCTUnwrap(app.setActivationPolicy(.accessory) ? true : nil,
                      "The native composer fixture requires an accessory application")
        defer { app.setActivationPolicy(previousPolicy) }
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 350),
                              styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // This scenario dispatches its own native events through window.sendEvent.
        // Keep unrelated WindowServer keyboard input out of the fixture.
        let keyboardMonitor = try XCTUnwrap(NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]) { _ in nil })
        defer { NSEvent.removeMonitor(keyboardMonitor) }
        window.contentView = NSHostingView(rootView: Fixture(state: state))
        // The runner may not own application activation. A native nonactivating
        // panel still accepts keyboard focus and exercises the real field editor.
        window.hidesOnDeactivate = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let timeout = Timer(timeInterval: 10, repeats: false) { _ in
            MainActor.assumeIsolated {
                XCTFail("Native composer verification timed out")
                NSApp.abortModal()
            }
        }
        // Default-mode timers do not fire while runModal is pumping AppKit.
        RunLoop.main.add(timeout, forMode: .common)
        defer { timeout.invalidate() }
        let task = Task { @MainActor in
            defer { NSApp.stopModal() }
            do {
                // Request focus after entering the modal loop, then wait for
                // AppKit and SwiftUI to establish the actual field editor.
                window.makeKeyAndOrderFront(nil)
                try await waitUntil("composer key window and field editor") {
                    app.keyWindow === window && window.firstResponder is NSTextView
                }
                try await Task.sleep(for: .milliseconds(200))
                let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
                editor.insertText("@", replacementRange: editor.selectedRange())
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertEqual(state.draft.text, "@")
                XCTAssertTrue(NSApp.keyWindow === window)
                XCTAssertEqual(editor.selectedRange().location, 1)
                let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: String(UnicodeScalar(NSDownArrowFunctionKey)!),
                    charactersIgnoringModifiers: String(UnicodeScalar(NSDownArrowFunctionKey)!), isARepeat: false, keyCode: 125))
                window.sendEvent(down)
                try await Task.sleep(for: .milliseconds(100))
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                    isARepeat: false, keyCode: 36))
                window.sendEvent(event)
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertEqual(state.draft.text, "@Reddit ")
                XCTAssertEqual(state.draft.references.map(\.item.id), [reddit.id])
                XCTAssertEqual(state.sends, 0)
                window.sendEvent(event)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(state.sends, 1)
                window.appearance = NSAppearance(named: .darkAqua)
                editor.insertText("@Red", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                try await Task.sleep(for: .milliseconds(100))
                let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53))
                window.sendEvent(escape)
                try await Task.sleep(for: .milliseconds(100))
                window.sendEvent(event)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(state.draft.text, "@Red")
                XCTAssertTrue(state.draft.references.isEmpty)
                XCTAssertEqual(state.sends, 2)
                let newline = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [.shift], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                    isARepeat: false, keyCode: 36))
                window.sendEvent(newline)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(state.draft.text, "@Red\n")
                XCTAssertEqual(state.sends, 2)
            } catch {
                XCTFail("Native composer verification failed: \(error)")
            }
        }
        NSApp.runModal(for: window)
        task.cancel()
    }

    private func waitUntil(_ description: String, condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try XCTUnwrap(condition() ? true : nil, "Timed out waiting for \(description)")
    }
}
