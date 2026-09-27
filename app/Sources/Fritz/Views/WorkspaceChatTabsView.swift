import Bonsplit
import SwiftUI

struct WorkspaceChatTabsView: View {
    @Bindable var state: FritzState
    let openProviders: () -> Void

    private var tabs: WorkspaceTabs { state.workspace.tabs }

    var body: some View {
        VStack(spacing: 0) {
            BonsplitTabBar(controller: tabs.controller, newTabTitle: "New Thread",
                           canCreateTab: !state.workspace.projects.isEmpty && state.workspace.canSave,
                           createTab: state.newThread) { tab, _ in
                Button("Close Tab") { tabs.controller.closeTab(tab.id) }
            }

            if let thread = state.workspace.selectedThread, let chat = state.workspace.selectedChat {
                ChatView(store: chat, providers: state.providers,
                         openProviders: openProviders,
                         addProvider: { state.editor = ProviderEditorSelection() })
                    .id(thread.id)
            } else {
                FritzWindowStyle.contentBackground
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(FritzWindowStyle.contentBackground)
        .onChange(of: tabs.orderedThreadIDs) { tabs.saveOrder() }
    }
}

private struct WorkspaceTabsFocusKey: FocusedValueKey {
    typealias Value = WorkspaceTabs
}

extension FocusedValues {
    var workspaceTabs: WorkspaceTabs? {
        get { self[WorkspaceTabsFocusKey.self] }
        set { self[WorkspaceTabsFocusKey.self] = newValue }
    }
}
