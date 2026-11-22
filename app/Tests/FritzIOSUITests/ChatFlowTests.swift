import XCTest

@MainActor
final class ChatFlowTests: XCTestCase {
    func testRemoteChatDiscoveryStreamingCancellationAndRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        let newChat = app.buttons["New Chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 10))
        newChat.tap()
        app.buttons["Add a Provider"].tap()
        app.buttons["Add Provider"].tap()
        app.buttons["provider-kind"].tap()
        app.buttons["OpenAI-compatible"].tap()

        let endpoint = app.textFields["provider-endpoint"]
        endpoint.tap()
        endpoint.typeText("http://127.0.0.1:18743/v1")
        app.buttons["Load Models"].tap()
        let discovered = app.buttons["Choose from 4 models"]
        XCTAssertTrue(discovered.waitForExistence(timeout: 12))
        discovered.tap()
        app.buttons["Fritz Test Model, fritz-test"].tap()

        let consent = app.switches["Allow Chat Sharing"]
        if !consent.isHittable { app.swipeUp() }
        consent.tap()
        app.buttons["Save Provider"].tap()
        app.buttons["Done"].tap()

        app.buttons["choose-model"].tap()
        XCTAssertEqual(app.textFields["model-id"].value as? String, "fritz-test")
        app.buttons["Use Model"].tap()
        let composer = app.descendants(matching: .any)["chat-composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        composer.tap()
        composer.typeText("What is Fritz?")
        app.buttons["send-message"].tap()
        let answer = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "A native chat foundation")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 10))

        replaceModel(in: app, current: "fritz-test", replacement: "error-test")
        composer.tap()
        composer.typeText("Check the provider error")
        app.buttons["send-message"].tap()
        let error = app.alerts["Fritz"]
        XCTAssertTrue(error.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "HTTP 401")).firstMatch.waitForExistence(timeout: 10))
        error.buttons["OK"].tap()

        replaceModel(in: app, current: "error-test", replacement: "slow-test")
        let retry = app.buttons["Retry Reply"]
        if !retry.isHittable { app.swipeUp() }
        retry.tap()
        let stop = app.buttons["stop-reply"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        XCTAssertTrue(app.staticTexts["Reply stopped"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "Check the provider error").count, 1)

        composer.tap()
        composer.typeText("A saved draft")
        // Backgrounding flushes pending edits before termination.
        XCUIDevice.shared.press(.home)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["What is Fritz?"].waitForExistence(timeout: 8))
        XCTAssertEqual(composer.value as? String, "A saved draft")
        XCTAssertTrue(app.buttons["choose-model"].label.contains("slow-test"))
    }

    private func replaceModel(in app: XCUIApplication, current: String, replacement: String) {
        app.buttons["choose-model"].tap()
        let field = app.textFields["model-id"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, current)
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + replacement)
        app.buttons["Use Model"].tap()
    }
}
