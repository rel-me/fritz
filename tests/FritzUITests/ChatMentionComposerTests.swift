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
        // SwiftPM provides no app host. Complete AppKit launch before starting
        // a modal loop, and allow the native editor to receive keyboard focus.
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        XCTAssertTrue(app.setActivationPolicy(.regular))
        defer { app.setActivationPolicy(previousPolicy) }
        app.finishLaunching()
        app.activate()
        let state = State()
        let reddit = ChatMentionItem(id: .init(source: "profiles", value: "reddit"),
                                    name: "Reddit", kind: .entity)
        try state.registry.register(source: "profiles", items: [reddit,
            .init(id: .init(source: "profiles", value: "oxylabs"), name: "Oxylabs", kind: .entity)
        ])
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 350),
                              styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Fixture(state: state))
        // Keep the field editor available if another app temporarily activates.
        window.hidesOnDeactivate = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let timeout = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in
            MainActor.assumeIsolated {
                XCTFail("Native composer verification timed out")
                NSApp.abortModal()
            }
        }
        defer { timeout.invalidate() }
        let task = Task { @MainActor in
            defer { NSApp.stopModal() }
            do {
                // SwiftUI installs the field editor after the modal loop starts.
                // Acquire key status there rather than relying on presentation timing.
                let deadline = ContinuousClock.now + .seconds(2)
                while NSApp.keyWindow !== window || !(window.firstResponder is NSTextView) {
                    guard ContinuousClock.now < deadline else {
                        XCTFail("Native composer panel did not acquire keyboard focus "
                                + "(active: \(app.isActive), policy: \(app.activationPolicy().rawValue), "
                                + "visible: \(window.isVisible), canBecomeKey: \(window.canBecomeKey), "
                                + "keyWindow: \(String(describing: app.keyWindow)), "
                                + "firstResponder: \(String(describing: window.firstResponder)))")
                        return
                    }
                    window.makeKey()
                    try await Task.sleep(for: .milliseconds(20))
                }
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
                // Use AppKit's event queue so SwiftUI sees the current event's
                // modifiers and the same dispatch path as physical keyboard input.
                app.postEvent(down, atStart: false)
                try await Task.sleep(for: .milliseconds(100))
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                    isARepeat: false, keyCode: 36))
                app.postEvent(event, atStart: false)
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertEqual(state.draft.text, "@Reddit ")
                XCTAssertEqual(state.draft.references.map(\.item.id), [reddit.id])
                XCTAssertEqual(state.sends, 0)
                app.postEvent(event, atStart: false)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(state.sends, 1)
                window.appearance = NSAppearance(named: .darkAqua)
                editor.insertText("@Red", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                try await Task.sleep(for: .milliseconds(100))
                let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53))
                app.postEvent(escape, atStart: false)
                try await Task.sleep(for: .milliseconds(100))
                app.postEvent(event, atStart: false)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(state.draft.text, "@Red")
                XCTAssertTrue(state.draft.references.isEmpty)
                XCTAssertEqual(state.sends, 2)
                let newline = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [.shift], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                    isARepeat: false, keyCode: 36))
                app.postEvent(newline, atStart: false)
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
}
