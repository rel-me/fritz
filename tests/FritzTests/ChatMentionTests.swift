import Fritz
import XCTest

final class ChatMentionTests: XCTestCase {
    private let reddit = ChatMentionItem(id: .init(source: "profiles", value: "reddit-1"),
                                        name: "Reddit", kind: .entity, detail: "Social profile")

    @MainActor func testSourceRefreshAndSearchPreserveDistinctIdentities() throws {
        let registry = ChatMentionRegistry()
        let proxy = ChatMentionItem(id: .init(source: "proxies", value: "reddit-1"),
                                   name: "Reddit", kind: .entity, detail: "Oxylabs proxy")
        try registry.register(source: "profiles", items: [reddit])
        try registry.register(source: "proxies", items: [proxy])
        XCTAssertEqual(registry.search("reddit").map(\.id), [reddit.id, proxy.id])
        XCTAssertEqual(registry.search("oxylabs").map(\.id), [proxy.id])
        XCTAssertThrowsError(try registry.register(source: "profiles", items: [reddit, reddit]))
        XCTAssertThrowsError(try registry.register(source: "profiles", items: [proxy]))
        XCTAssertEqual(registry.search("reddit").count, 2)
        try registry.register(source: "profiles", items: [])
        XCTAssertEqual(registry.search("").map(\.id), [proxy.id])
        registry.unregister(source: "proxies")
        XCTAssertTrue(registry.search("").isEmpty)
    }

    func testSelectionPersistsIdentityAndTracksEditsWithoutResolvingOrdinaryText() throws {
        var draft = ChatMentionDraft(text: "😀 Ask @Red")
        let query = try XCTUnwrap(draft.query(at: NSRange(location: draft.text.utf16.count, length: 0)))
        XCTAssertEqual(query.text, "Red")
        XCTAssertEqual(draft.insert(reddit, replacing: query.range), 15)
        XCTAssertEqual(draft.text, "😀 Ask @Reddit ")
        XCTAssertEqual(draft.references.first?.range, NSRange(location: 7, length: 7))
        XCTAssertEqual(draft.references.first?.item.id, reddit.id)
        let restored = try JSONDecoder().decode(ChatMentionDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(restored, draft)
        draft.updateText("Hello " + draft.text)
        XCTAssertEqual(draft.references.first?.range, NSRange(location: 13, length: 7))
        draft.updateText(draft.text + "and @Reddit")
        XCTAssertEqual(draft.references.count, 1)
        draft.updateText(draft.text.replacingOccurrences(of: "@Reddit ", with: "@Reddix "))
        XCTAssertTrue(draft.references.isEmpty)
    }

    func testDeletingIdenticalLabelsNeverRetargetsAReference() {
        var draft = ChatMentionDraft()
        _ = draft.insert(reddit, replacing: NSRange(location: 0, length: 0))
        let other = ChatMentionItem(id: .init(source: "profiles", value: "other-reddit"),
                                    name: "Reddit", kind: .entity)
        _ = draft.insert(other, replacing: NSRange(location: draft.text.utf16.count, length: 0))
        XCTAssertEqual(draft.references.count, 2)
        // A string-only editor cannot distinguish deletion of the first identical
        // label from deletion of the second. Neither identity may survive by guessing.
        draft.updateText("@Reddit ")
        XCTAssertTrue(draft.references.isEmpty)
    }

    func testQueryUsesCaretAndIgnoresEmailSelectedTextAndCompletedReferences() throws {
        for text in ["me@Red", "@Red next", "@Red\nnext"] {
            XCTAssertNil(ChatMentionDraft(text: text).query(at: NSRange(location: text.utf16.count, length: 0)))
        }
        var draft = ChatMentionDraft(text: "@Red suffix")
        XCTAssertNil(draft.query(at: NSRange(location: 4, length: 1)))
        let query = try XCTUnwrap(draft.query(at: NSRange(location: 4, length: 0)))
        _ = draft.insert(reddit, replacing: query.range)
        XCTAssertEqual(draft.text, "@Reddit  suffix")
        XCTAssertNil(draft.query(at: NSRange(location: 7, length: 0)))
        _ = draft.insert(reddit, replacing: NSRange(location: 0, length: 8))
        XCTAssertEqual(draft.references.count, 1)
        draft.updateText("@Reddit @Red")
        XCTAssertEqual(draft.query(at: NSRange(location: 12, length: 0))?.text, "Red")
        draft.updateText("")
        XCTAssertTrue(draft.references.isEmpty)
    }
}
