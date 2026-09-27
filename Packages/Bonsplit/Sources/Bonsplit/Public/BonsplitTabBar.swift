import SwiftUI

/// A content-sized, standalone strip with REL's trailing new-tab control.
/// Use this when the host owns content presentation separately from the tab strip.
public struct BonsplitTabBar<TabContextMenu: View>: View {
    @Bindable private var controller: BonsplitController
    private let newTabTitle: String
    private let canCreateTab: Bool
    private let createTab: () -> Void
    private let tabContextMenu: (Tab, PaneID) -> TabContextMenu

    public init(
        controller: BonsplitController,
        newTabTitle: String = "New Tab",
        canCreateTab: Bool = true,
        createTab: @escaping () -> Void,
        @ViewBuilder tabContextMenu: @escaping (Tab, PaneID) -> TabContextMenu
    ) {
        self.controller = controller
        self.newTabTitle = newTabTitle
        self.canCreateTab = canCreateTab
        self.createTab = createTab
        self.tabContextMenu = tabContextMenu
    }

    public var body: some View {
        GeometryReader { geometry in
            let widths = controller.allTabIds.compactMap { controller.tab($0) }.map {
                min(controller.configuration.appearance.tabMaxWidth,
                    max(controller.configuration.appearance.tabMinWidth,
                        BonsplitTabStyle.tabWidth(title: $0.title, hasIcon: $0.icon != nil)))
            }
            BonsplitView(controller: controller) { _, _ in
                Color.clear
            } emptyPane: { _ in
                Color.clear
            } tabContextMenu: { tab, pane in
                tabContextMenu(tab, pane)
            }
            .frame(width: min(max(0, geometry.size.width), BonsplitTabStyle.barWidth(tabWidths: widths)))
            .overlay(alignment: .topTrailing) {
                BonsplitNewTabButton(newTabTitle, action: createTab)
                    .disabled(!canCreateTab)
            }
        }
        .frame(height: BonsplitTabStyle.barHeight)
        .clipped()
        .background(controller.configuration.appearance.tabBarBackground
                    ?? Color(nsColor: BonsplitTabStyle.stripBackground))
    }
}

extension BonsplitTabBar where TabContextMenu == EmptyView {
    public init(controller: BonsplitController, newTabTitle: String = "New Tab",
                canCreateTab: Bool = true, createTab: @escaping () -> Void) {
        self.init(controller: controller, newTabTitle: newTabTitle,
                  canCreateTab: canCreateTab, createTab: createTab,
                  tabContextMenu: { _, _ in EmptyView() })
    }
}
