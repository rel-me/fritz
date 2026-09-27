import Bonsplit
import SwiftUI

/// A tabbed auxiliary surface. Conversations remain in the main workspace.
struct WorkspaceRightPanel: View {
    let controller: BonsplitController
    let close: () -> Void

    static func makeController() -> BonsplitController {
        let controller = BonsplitController(configuration: .init(
            allowSplits: false, allowCrossPaneTabMove: false,
            autoCloseEmptyPanes: false, newTabPosition: .end,
            appearance: .init(showSplitButtons: false)
        ))
        for tab in controller.allTabIds { controller.closeTab(tab) }
        controller.createTab(title: "Details", icon: "doc.text")
        return controller
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                BonsplitTabBar(controller: controller, createTab: {
                    controller.createTab(title: "Untitled", icon: "doc.text")
                }) { tab, _ in
                    Button("Close Tab") { controller.closeTab(tab.id) }
                }
                Button("Close Right Panel", systemImage: "xmark", action: close)
                    .modifier(FritzPanelIconControl())
                    .padding(.trailing, 8)
            }
            .background(FritzWindowStyle.workspaceBackground)

            FritzWindowStyle.contentBackground
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
