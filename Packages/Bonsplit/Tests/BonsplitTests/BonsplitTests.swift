import XCTest
@testable import Bonsplit

final class BonsplitTests: XCTestCase {

    @MainActor
    func testControllerCreation() {
        let controller = BonsplitController()
        XCTAssertNotNil(controller.focusedPaneId)
    }

    @MainActor
    func testTabCreation() {
        let controller = BonsplitController()
        let tabId = controller.createTab(title: "Test Tab", icon: "doc")
        XCTAssertNotNil(tabId)
    }

    @MainActor
    func testTabRetrieval() {
        let controller = BonsplitController()
        let tabId = controller.createTab(title: "Test Tab", icon: "doc")!
        let tab = controller.tab(tabId)
        XCTAssertEqual(tab?.title, "Test Tab")
        XCTAssertEqual(tab?.icon, "doc")
    }

    @MainActor
    func testTabCreationCanPreserveSelection() throws {
        let controller = BonsplitController()
        for tabID in controller.allTabIds {
            _ = controller.closeTab(tabID)
        }
        let firstTabID = try XCTUnwrap(controller.createTab(title: "First"))
        let secondTabID = try XCTUnwrap(
            controller.createTab(title: "Second", select: false)
        )
        let insertedTabID = try XCTUnwrap(
            controller.createTab(title: "Inserted", atIndex: 1, select: false)
        )
        let paneID = try XCTUnwrap(controller.allPaneIds.first)

        XCTAssertEqual(controller.selectedTab(inPane: paneID)?.id, firstTabID)
        XCTAssertEqual(
            controller.tabs(inPane: paneID).map(\.id),
            [firstTabID, insertedTabID, secondTabID]
        )
    }

    @MainActor
    func testTabUpdate() {
        let controller = BonsplitController()
        let tabId = controller.createTab(title: "Original", icon: "doc")!

        controller.updateTab(tabId, title: "Updated", isDirty: true)

        let tab = controller.tab(tabId)
        XCTAssertEqual(tab?.title, "Updated")
        XCTAssertEqual(tab?.isDirty, true)
    }

    @MainActor
    func testTabClose() {
        let controller = BonsplitController()
        let tabId = controller.createTab(title: "Test Tab", icon: "doc")!

        let closed = controller.closeTab(tabId)

        XCTAssertTrue(closed)
        XCTAssertNil(controller.tab(tabId))
    }

    @MainActor
    func testReadOnlyTabsCannotBeClosedThroughEitherPublicAPI() throws {
        for closeInPane in [false, true] {
            let controller = BonsplitController(configuration: .readOnly)
            let tab = try XCTUnwrap(controller.allTabIds.first)
            let pane = try XCTUnwrap(controller.allPaneIds.first)
            let closed = closeInPane ? controller.closeTab(tab, inPane: pane) : controller.closeTab(tab)
            XCTAssertFalse(closed)
            XCTAssertEqual(controller.selectedTab(inPane: pane)?.id, tab)
        }
    }

    @MainActor
    func testConfiguration() {
        let config = BonsplitConfiguration(
            allowSplits: false,
            allowCloseTabs: true,
            appearance: .init(
                tabBarBackground: .red,
                activeTabBackground: .blue
            )
        )
        let controller = BonsplitController(configuration: config)

        XCTAssertFalse(controller.configuration.allowSplits)
        XCTAssertTrue(controller.configuration.allowCloseTabs)
        XCTAssertNotNil(controller.configuration.appearance.tabBarBackground)
        XCTAssertNotNil(controller.configuration.appearance.activeTabBackground)
    }

    func testTabCloseButtonsAppearOnlyOnHover() {
        XCTAssertFalse(TabItemView.showsCloseButton(
            allowsClose: true, isHovered: false, isCloseHovered: false
        ))
        XCTAssertFalse(TabItemView.showsCloseButton(
            allowsClose: true, isDirty: true, isHovered: false, isCloseHovered: false
        ))
        XCTAssertTrue(TabItemView.showsCloseButton(
            allowsClose: true, isDirty: true, isHovered: true, isCloseHovered: false
        ))
    }

    func testTabCloseButtonVisibilityFollowsConfiguration() {
        XCTAssertTrue(
            TabItemView.showsCloseButton(
                allowsClose: true,
                isHovered: true,
                isCloseHovered: false
            )
        )
        XCTAssertFalse(
            TabItemView.showsCloseButton(
                allowsClose: false,
                isHovered: true,
                isCloseHovered: true
            )
        )
    }
}
