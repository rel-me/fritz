import AppKit
import NativeMarkupCore
import NativeMarkupUI
import Observation
import SwiftUI
import XCTest

@MainActor
final class MarkupSessionTests: XCTestCase {
    // The session owns atomic installation; parser tests cannot protect retention of
    // a previously installed native document and its independently owned host state.
    func testFailedReplacementPreservesDocumentAndHostState() {
        var note = "Draft survives"
        let context = MarkupContext()
        context.registerBinding("note", get: { note }, set: { note = $0 })
        let session = MarkupSession(context: context)
        XCTAssertTrue(session.apply(source: #"<Interface version="1"><TextField id="editor" text="$note"/></Interface>"#))

        XCTAssertFalse(session.apply(source: #"<Interface version="1"><Missing id="replacement"/></Interface>"#))
        XCTAssertEqual(session.document?.root.id, "editor")
        XCTAssertEqual(note, "Draft survives")
        XCTAssertNotNil(session.diagnostic)

        note = "Still editable"
        session.refresh()
        XCTAssertNotNil(session.diagnostic, "Refreshing a valid document must not hide a rejected source edit.")
        XCTAssertTrue(session.apply(source: #"<Interface version="1"><TextField id="editor" title="Updated" text="$note"/></Interface>"#))
        XCTAssertNil(session.diagnostic)
        XCTAssertEqual(note, "Still editable")
    }

    // The renderer's registered native vocabulary, not the generic parser, owns
    // native parameter types, legal styles, ranges, and reserved names.
    func testNativeVocabularyRejectsInvalidCapabilitiesAndValues() {
        let context = MarkupContext()
        context.registerBinding("enabled", get: { true }, set: { _ in })
        let session = MarkupSession(context: context)
        let invalidBodies = [
            #"<TextField id="input" text="$enabled"/>"#,
            #"<Button id="button" title="Save" action="missing"/>"#,
            #"<Unknown id="unknown"/>"#,
            #"<Text id="text" value="Hello"><Modifiers><Font style="imaginary"/></Modifiers></Text>"#,
            #"<Text id="text" value="Hello"><Modifiers><ForegroundStyle color="imaginary"/></Modifiers></Text>"#,
            #"<Text id="text" value="Hello"><Modifiers><Frame width="-1"/></Modifiers></Text>"#,
            #"<Text id="text" value="Hello"><Modifiers><Opacity value="2"/></Modifiers></Text>"#,
        ]
        for body in invalidBodies {
            XCTAssertFalse(session.apply(source: "<Interface version=\"1\">\(body)</Interface>"), body)
            XCTAssertNotNil(session.diagnostic, body)
            XCTAssertNil(session.document, body)
        }
        context.registerComponent("Text", specification: .init()) { _ in AnyView(EmptyView()) }
        XCTAssertFalse(session.apply(source: #"<Interface version="1"><Text id="reserved"/></Interface>"#))
        XCTAssertTrue(session.diagnostic?.contains("reserved") == true)
    }

    // An expression can validate initially and become invalid after host state changes.
    // This is a session lifecycle contract absent from pure expression unit tests.
    func testRuntimeEvaluationFailureIsVisibleAndRecoverable() {
        var divisor = 2.0
        let context = MarkupContext()
        context.registerBinding("divisor", get: { divisor }, set: { divisor = $0 })
        let session = MarkupSession(context: context)
        XCTAssertTrue(session.apply(source: #"<Interface version="1"><Text id="content" value="Example"><Modifiers><Frame width="{{ 10 / divisor }}"/></Modifiers></Text></Interface>"#))

        divisor = 0
        session.refresh()
        XCTAssertNotNil(session.diagnostic)
        XCTAssertTrue(session.diagnostic?.contains("Line") == true)
        XCTAssertEqual(session.document?.root.id, "content")

        divisor = 5
        session.refresh()
        XCTAssertNil(session.diagnostic)
    }

    // The custom renderer callback is the public component SDK boundary: exercise
    // actual resolved capability delivery, including read-only versus writable props.
    func testNativeExtensionsReceiveTypedBindingsActionsAndOrderedModifiers() throws {
        var note = "Original"
        var saved = ""
        var delivered: MarkupComponentContent?
        var modifierOrder: [String] = []
        let context = MarkupContext()
        context.registerBinding("note", get: { note }, set: { note = $0 })
        context.registerAction("save") { saved = note }
        context.registerComponent("Editor", specification: .init(properties: [
            "text": .init(type: .string, kind: .binding, required: true),
            "title": .init(type: .string, required: true),
            "save": .init(type: .string, kind: .action, required: true),
        ])) { content in
            delivered = content
            return AnyView(Text("Native component"))
        }
        context.registerModifier("Trace", specification: .init(properties: [
            "label": .init(type: .string, required: true),
        ])) { view, content in
            if case let .string(label) = content.values["label"] { modifierOrder.append(label) }
            return view
        }
        let session = MarkupSession(context: context)
        XCTAssertTrue(session.apply(source: #"<Interface version="1"><Editor id="editor" text="$note" title="$note" save="save"><Modifiers><Trace label="first"/><Trace label="second"/></Modifiers></Editor></Interface>"#))
        XCTAssertEqual(saved, "", "Loading a document must not execute native actions.")

        let renderer = ImageRenderer(content: MarkupView(session: session).frame(width: 240, height: 80))
        XCTAssertNotNil(renderer.nsImage)
        let content = try XCTUnwrap(delivered)
        XCTAssertEqual(content.values["title"], .string("Original"))
        XCTAssertNil(content.bindings["title"], "A read-only value reference must not grant write access.")
        guard case let .string(binding) = content.bindings["text"] else {
            return XCTFail("The registered String binding was not delivered.")
        }
        binding.wrappedValue = "Edited by component"
        try XCTUnwrap(content.actions["save"])()
        XCTAssertEqual(note, "Edited by component")
        XCTAssertEqual(saved, "Edited by component")
        XCTAssertEqual(Array(modifierOrder.suffix(2)), ["first", "second"])

        // Re-registration does not invalidate an already validated, installed document.
        context.registerBinding("note", get: { false }, set: { _ in })
        session.refresh()
        XCTAssertNil(session.diagnostic)
        XCTAssertFalse(session.apply(source: #"<Interface version="1"><TextField id="input" text="$note"/></Interface>"#))
        XCTAssertEqual(session.document?.root.id, "editor")
    }

    // A mounted SwiftUI graph must observe the host getter itself. Evaluating or
    // refreshing manually outside a view misses cached Binding reads inside body.
    func testMountedViewTracksObservableHostWithoutManualRefresh() throws {
        let hostState = ObservableMarkupHost()
        let context = MarkupContext()
        context.registerBinding("note", get: { hostState.note }, set: { hostState.note = $0 })
        context.registerBinding("enabled", get: { hostState.enabled }, set: { hostState.enabled = $0 })
        var displayed: String?
        var delivered: MarkupComponentContent?
        context.registerComponent("Preview", specification: .init(properties: [
            "value": .init(type: .string, required: true),
            "enabled": .init(type: .bool, required: true),
            "edit": .init(type: .string, kind: .binding, required: true),
            "toggle": .init(type: .bool, kind: .binding, required: true),
        ])) { content in
            delivered = content
            guard case let .string(note) = content.values["value"],
                  case let .bool(enabled) = content.values["enabled"] else {
                return AnyView(EmptyView())
            }
            let text = "\(note):\(enabled)"
            displayed = text
            return AnyView(Text(text))
        }
        let session = MarkupSession(context: context)
        XCTAssertTrue(session.apply(source: #"<Interface version="1"><Preview id="preview" value="$note" enabled="$enabled" edit="$note" toggle="$enabled"/></Interface>"#))
        _ = NSApplication.shared
        let bounds = NSRect(x: 0, y: 0, width: 240, height: 80)
        let host = NSHostingView(rootView: MarkupView(session: session))
        host.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        func settle(until expected: String) {
            let deadline = Date(timeIntervalSinceNow: 1)
            repeat {
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            } while displayed != expected && Date() < deadline
        }
        settle(until: "Before:true")
        XCTAssertEqual(displayed, "Before:true")

        hostState.note = "Host edit"
        hostState.enabled = false
        settle(until: "Host edit:false")
        XCTAssertEqual(displayed, "Host edit:false")

        let content = try XCTUnwrap(delivered)
        guard case let .string(text) = content.bindings["edit"],
              case let .bool(toggle) = content.bindings["toggle"] else {
            return XCTFail("Native control bindings were not delivered.")
        }
        text.wrappedValue = "Control edit"
        toggle.wrappedValue = true
        settle(until: "Control edit:true")
        XCTAssertEqual(displayed, "Control edit:true")
        XCTAssertEqual(hostState.note, "Control edit")
        XCTAssertTrue(hostState.enabled)
        XCTAssertNil(session.diagnostic)
    }
}

@MainActor @Observable
private final class ObservableMarkupHost {
    var note = "Before"
    var enabled = true
}
