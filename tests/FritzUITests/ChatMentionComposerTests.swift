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
        guard ProcessInfo.processInfo.environment["FRITZ_INTERACTIVE_UI_TESTS"] == "1" else {
            throw XCTSkip("Requires foreground keyboard focus; see docs/agents/ui-verification.md for the opt-in command.")
        }
        let state = State()
        let reddit = ChatMentionItem(id: .init(source: "profiles", value: "reddit"),
                                    name: "Reddit", kind: .entity)
        try state.registry.register(source: "profiles", items: [reddit,
            .init(id: .init(source: "profiles", value: "oxylabs"), name: "Oxylabs", kind: .entity)
        ])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 350),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Fixture(state: state))
        let previousPolicy = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(previousPolicy) }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
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
}
