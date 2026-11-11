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

    private final class BackgroundPanel: NSPanel {
        override var canBecomeKey: Bool { false }
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
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        _ = app.setActivationPolicy(.prohibited)
        XCTAssertEqual(app.activationPolicy(), .prohibited)
        defer { app.setActivationPolicy(previousPolicy) }
        let state = State()
        let reddit = ChatMentionItem(id: .init(source: "profiles", value: "reddit"),
                                    name: "Reddit", kind: .entity)
        try state.registry.register(source: "profiles", items: [reddit,
            .init(id: .init(source: "profiles", value: "oxylabs"), name: "Oxylabs", kind: .entity)
        ])
        let window = BackgroundPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 350),
                              styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // This scenario dispatches its own native events through window.sendEvent.
        // Keep unrelated WindowServer keyboard input out of the fixture.
        let keyboardMonitor = try XCTUnwrap(NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]) { _ in nil })
        defer { NSEvent.removeMonitor(keyboardMonitor) }
        window.contentView = NSHostingView(rootView: Fixture(state: state))
        // Keep the native editor in an offscreen window without requesting
        // application activation or foreground keyboard focus.
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        defer { window.close() }
        let otherEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        otherEditor.string = "@"
        otherEditor.setSelectedRange(NSRange(location: 1, length: 0))
        let otherWindow = BackgroundPanel(contentRect: otherEditor.frame,
                                  styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        otherWindow.worksWhenModal = true
        otherWindow.hidesOnDeactivate = false
        otherWindow.contentView = otherEditor
        defer { otherWindow.close() }
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
                // Wait for SwiftUI to install the real field editor in its
                // owning window before dispatching native keyboard events.
                try await waitForComposerEditor(in: window)
                try await Task.sleep(for: .milliseconds(200))
                let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
                // Matching text in another window must not own this edit,
                // even when neither window can acquire key status.
                otherWindow.setFrameOrigin(NSPoint(x: -10000, y: -10000))
                otherWindow.orderFrontRegardless()
                XCTAssertTrue(otherWindow.makeFirstResponder(otherEditor))
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertFalse(app.keyWindow === window)
                XCTAssertTrue(window.firstResponder === editor)
                editor.insertText("@", replacementRange: editor.selectedRange())
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertEqual(state.draft.text, "@")
                XCTAssertTrue(window.firstResponder === editor)
                XCTAssertFalse(app.isActive)
                XCTAssertFalse(window.isKeyWindow)
                XCTAssertFalse(NSApp.keyWindow === window)
                XCTAssertTrue(editor.window === window)
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
                XCTAssertEqual(otherEditor.string, "@", "Composer keys must not edit another window")
            } catch {
                XCTFail("Native composer verification failed: \(error)")
            }
        }
        NSApp.runModal(for: window)
        task.cancel()
    }

    private func waitForComposerEditor(in window: NSWindow) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        func isReady() -> Bool {
            guard let editor = window.firstResponder as? NSTextView else { return false }
            return editor.window === window
        }
        while !isReady(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let responder = window.firstResponder.map { String(reflecting: type(of: $0)) } ?? "nil"
        _ = try XCTUnwrap(isReady() ? true : nil,
                      "Composer focus unavailable: policy=\(NSApp.activationPolicy().rawValue), " +
                      "active=\(NSApp.isActive), visible=\(window.isVisible), " +
                      "canBecomeKey=\(window.canBecomeKey), key=\(window.isKeyWindow), " +
                      "responder=\(responder)")
    }
}
