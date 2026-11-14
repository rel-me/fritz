import SwiftUI

/// Manual browsing beside the conversation, with tabs owned by the workspace.
struct WorkspaceRightPanel: View {
    let tabs: BrowserTabs
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Browser")
                    .font(.headline)
                Spacer()
                Button("Close Browser", systemImage: "xmark", action: close)
                    .modifier(FritzPanelIconControl())
            }
            .padding(8)
            BrowserPanel(tabs: tabs)
        }
        .background(FritzWindowStyle.contentBackground)
        .clipShape(RoundedRectangle(cornerRadius: FritzWindowStyle.cornerRadius, style: .continuous))
        .padding(.leading, 4).padding(.trailing, 8).padding(.bottom, 8)
        .background { FritzWorkspaceBackground().ignoresSafeArea() }
    }
}
