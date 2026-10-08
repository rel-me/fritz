import SwiftUI

/// A blank auxiliary surface. Conversations remain in the main workspace.
struct WorkspaceRightPanel: View {
    let close: () -> Void

    var body: some View {
        FritzWindowStyle.contentBackground
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                Button("Close Right Panel", systemImage: "xmark", action: close)
                    .modifier(FritzPanelIconControl())
                    .padding(8)
            }
    }
}
