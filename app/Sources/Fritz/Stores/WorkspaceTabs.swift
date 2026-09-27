import Bonsplit
import Foundation
import Observation

/// App-owned conversation identity and persistence around the reusable tab library.
@MainActor @Observable final class WorkspaceTabs {
    let controller: BonsplitController
    private weak var workspace: WorkspaceStore?
    private var threadIDs: [TabID: UUID] = [:]
    private var isSynchronizing = false
    private var canSave = true
    private var lastSavedOrder: [UUID] = []

    init(workspace: WorkspaceStore) {
        self.workspace = workspace
        controller = BonsplitController(configuration: .init(
            allowSplits: false, allowCrossPaneTabMove: false,
            autoCloseEmptyPanes: false, newTabPosition: .end,
            appearance: .init(showSplitButtons: false)
        ))
        for id in controller.allTabIds { controller.closeTab(id) }
        do {
            let saved = try workspace.database.setting("workspace.openTabs", as: [UUID].self)
                ?? workspace.selectedThreadID.map { [$0] } ?? []
            for id in saved where !orderedThreadIDs.contains(id) { open(id) }
            lastSavedOrder = orderedThreadIDs
        } catch {
            canSave = false
            workspace.error = "Could not restore tabs: \(error.localizedDescription)"
        }
        controller.delegate = self
        synchronize()
    }

    var orderedThreadIDs: [UUID] { controller.allTabIds.compactMap { threadIDs[$0] } }
    var selectedThreadID: UUID? {
        guard let pane = controller.allPaneIds.first,
              let tab = controller.selectedTab(inPane: pane) else { return nil }
        return threadIDs[tab.id]
    }

    func synchronize() {
        guard !isSynchronizing, let workspace else { return }
        isSynchronizing = true
        defer { isSynchronizing = false }
        for (tabID, threadID) in threadIDs {
            if let thread = thread(threadID), controller.tab(tabID)?.title != thread.title {
                controller.updateTab(tabID, title: thread.title)
            }
        }
        if let selected = workspace.selectedThreadID {
            open(selected)
            if let tabID = controller.allTabIds.first(where: { threadIDs[$0] == selected }),
               selectedThreadID != selected {
                controller.selectTab(tabID)
            }
        }
        saveOrder()
    }

    func saveOrder() {
        let order = orderedThreadIDs
        guard canSave, order != lastSavedOrder, let workspace else { return }
        do {
            try workspace.database.set(order, for: "workspace.openTabs")
            lastSavedOrder = order
        } catch {
            workspace.error = "Could not save tabs: \(error.localizedDescription)"
        }
    }

    func closeSelectedTab() {
        guard let pane = controller.allPaneIds.first,
              let tab = controller.selectedTab(inPane: pane) else { return }
        controller.closeTab(tab.id)
    }

    private func thread(_ id: UUID) -> ProjectThread? {
        workspace?.projects.flatMap(\.threads).first { $0.id == id }
    }

    private func open(_ id: UUID) {
        guard !threadIDs.values.contains(id), let thread = thread(id),
              let tabID = controller.createTab(title: thread.title, icon: "bubble.left.and.bubble.right", select: false) else { return }
        threadIDs[tabID] = id
    }
}

extension WorkspaceTabs: @preconcurrency BonsplitDelegate {
    func splitTabBar(_ controller: BonsplitController, didSelectTab tab: Tab, inPane pane: PaneID) {
        guard !isSynchronizing, let id = threadIDs[tab.id] else { return }
        workspace?.select(id)
    }

    func splitTabBar(_ controller: BonsplitController, didFocusPane pane: PaneID) {
        guard let tab = controller.selectedTab(inPane: pane) else { return }
        splitTabBar(controller, didSelectTab: tab, inPane: pane)
    }

    func splitTabBar(_ controller: BonsplitController, didCloseTab tabID: TabID, fromPane pane: PaneID) {
        threadIDs[tabID] = nil
        workspace?.select(selectedThreadID)
        saveOrder()
    }
}
