import SwiftUI

/// Manual browsing beside the conversation, with tabs owned by the workspace.
struct WorkspaceRightPanel: View {
    let tabs: BrowserTabs

    var body: some View {
        BrowserPanel(tabs: tabs)
        .background(FritzWindowStyle.contentBackground)
        .clipShape(RoundedRectangle(cornerRadius: FritzWindowStyle.cornerRadius, style: .continuous))
        .padding(.leading, 4).padding(.trailing, 8).padding(.bottom, 8)
        .background { FritzWorkspaceBackground().ignoresSafeArea() }
    }
}
