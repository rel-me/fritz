import SwiftUI

/// A blank native inspector. Conversations remain in the main workspace.
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
            .clipShape(RoundedRectangle(cornerRadius: FritzWindowStyle.cornerRadius, style: .continuous))
            .padding(.leading, 4).padding(.trailing, 8).padding(.bottom, 8)
            .background { FritzWorkspaceBackground().ignoresSafeArea() }
    }
}
