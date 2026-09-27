import SwiftUI
import UniformTypeIdentifiers

/// Tab bar view with compressible tabs and an overflow menu, drag/drop support, and split buttons
struct TabBarView: View {
    @Environment(BonsplitController.self) private var controller
    @Environment(SplitViewController.self) private var splitViewController

    @Bindable var pane: PaneState
    let isFocused: Bool
    var showSplitButtons: Bool = true
    let tabContextMenuBuilder: (TabItem, PaneID) -> AnyView

    @State private var dropTargetIndex: Int?

    /// Whether this tab bar should show full saturation (focused or drag source)
    private var shouldShowFullSaturation: Bool {
        isFocused || splitViewController.dragSourcePaneId == pane.id
    }

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { geometry in
                let layout = TabStripLayout(
                    preferredWidths: pane.tabs.map {
                        min(controller.configuration.appearance.tabMaxWidth,
                            max(controller.configuration.appearance.tabMinWidth,
                                BonsplitTabStyle.tabWidth(title: $0.title, hasIcon: $0.icon != nil)))
                    },
                    selectedIndex: pane.tabs.firstIndex { $0.id == pane.selectedTabId },
                    availableWidth: geometry.size.width,
                    minimumWidth: controller.configuration.appearance.tabMinWidth
                )
                HStack(alignment: .bottom, spacing: TabBarMetrics.tabSpacing) {
                    ForEach(Array(pane.tabs.enumerated()).filter { layout.visibleIndices.contains($0.offset) },
                            id: \.element.id) { index, tab in
                        tabItem(for: tab, at: index,
                                width: layout.tabWidths[index] ?? 0,
                                showsSeparator: layout.visibleIndices.last != index
                                    && layout.visibleIndices.first(where: { $0 > index })
                                        .map { pane.tabs[$0].id != pane.selectedTabId } == true)
                    }
                    if !layout.hiddenIndices.isEmpty {
                        Menu {
                            ForEach(layout.hiddenIndices, id: \.self) { index in
                                let tab = pane.tabs[index]
                                Button {
                                    pane.selectTab(tab.id)
                                    controller.focusPane(pane.id)
                                } label: {
                                    Label(tab.title, systemImage: tab.icon ?? "rectangle.on.rectangle")
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: TabStripLayout.overflowWidth, height: TabBarMetrics.tabHeight)
                        .help("More tabs (\(layout.hiddenIndices.count))")
                        .accessibilityLabel("More tabs")
                    }
                    dropZoneAtEnd
                }
                .padding(.leading, BonsplitTabStyle.barLeadingPadding)
                .padding(.top, TabBarMetrics.topPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Split buttons
            if showSplitButtons {
                splitButtons
            }
        }
        .frame(height: TabBarMetrics.barHeight)
        .contentShape(Rectangle())
        .background(tabBarBackground)
        .saturation(shouldShowFullSaturation ? 1.0 : 0)
    }

    // MARK: - Tab Item

    @ViewBuilder
    private func tabItem(for tab: TabItem, at index: Int, width: CGFloat, showsSeparator: Bool) -> some View {
        TabItemView(
            tab: tab,
            isSelected: pane.selectedTabId == tab.id,
            allowsClose: controller.configuration.allowCloseTabs,
            showsSeparator: showsSeparator,
            allocatedWidth: width,
            appearance: controller.configuration.appearance,
            onSelect: {
                withAnimation(.easeInOut(duration: TabBarMetrics.selectionDuration)) {
                    pane.selectTab(tab.id)
                    controller.focusPane(pane.id)
                }
            },
            onClose: {
                withAnimation(.easeInOut(duration: TabBarMetrics.closeDuration)) {
                    _ = controller.closeTab(TabID(id: tab.id), inPane: pane.id)
                }
            }
        )
        .zIndex(pane.selectedTabId == tab.id ? 1 : 0)
        .contextMenu {
            tabContextMenuBuilder(tab, pane.id)
        }
        .onDrag {
            createItemProvider(for: tab)
        } preview: {
            TabDragPreview(
                tab: tab,
                appearance: controller.configuration.appearance
            )
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(
            targetIndex: index,
            pane: pane,
            controller: splitViewController,
            dropTargetIndex: $dropTargetIndex
        ))
        .overlay(alignment: .leading) {
            if dropTargetIndex == index {
                dropIndicator
            }
        }
    }

    // MARK: - Item Provider

    private func createItemProvider(for tab: TabItem) -> NSItemProvider {
        // Set drag source for visual feedback
        splitViewController.draggingTab = tab
        splitViewController.dragSourcePaneId = pane.id

        let transfer = TabTransferData(tab: tab, sourcePaneId: pane.id.id)
        if let data = try? JSONEncoder().encode(transfer),
           let string = String(data: data, encoding: .utf8) {
            return NSItemProvider(object: string as NSString)
        }
        return NSItemProvider()
    }

    // MARK: - Drop Zone at End

    @ViewBuilder
    private var dropZoneAtEnd: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: BonsplitTabStyle.dropZoneWidth, height: TabBarMetrics.tabHeight)
            .contentShape(Rectangle())
            .onDrop(of: [.text], delegate: TabDropDelegate(
                targetIndex: pane.tabs.count,
                pane: pane,
                controller: splitViewController,
                dropTargetIndex: $dropTargetIndex
            ))
            .overlay(alignment: .leading) {
                if dropTargetIndex == pane.tabs.count {
                    dropIndicator
                }
            }
    }

    // MARK: - Drop Indicator

    @ViewBuilder
    private var dropIndicator: some View {
        Capsule()
            .fill(TabBarColors.dropIndicator)
            .frame(width: TabBarMetrics.dropIndicatorWidth, height: TabBarMetrics.dropIndicatorHeight)
            .offset(x: -1)
            .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Split Buttons

    @ViewBuilder
    private var splitButtons: some View {
        HStack(spacing: 4) {
            Button {
                // 120fps animation handled by SplitAnimator
                controller.splitPane(pane.id, orientation: .horizontal)
            } label: {
                Image(systemName: "square.split.2x1")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Split Right")

            Button {
                // 120fps animation handled by SplitAnimator
                controller.splitPane(pane.id, orientation: .vertical)
            } label: {
                Image(systemName: "square.split.1x2")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Split Down")
        }
        .padding(.trailing, 8)
    }

    // MARK: - Background

    @ViewBuilder
    private var tabBarBackground: some View {
        let background = TabBarColors.barBackground(
            for: controller.configuration.appearance
        )

        Rectangle()
            .fill(background)
    }
}

// MARK: - Tab Drop Delegate

struct TabDropDelegate: DropDelegate {
    let targetIndex: Int
    let pane: PaneState
    let controller: SplitViewController
    @Binding var dropTargetIndex: Int?

    func performDrop(info: DropInfo) -> Bool {
        dropTargetIndex = nil

        guard let provider = info.itemProviders(for: [.text]).first else {
            // Clear drag state
            controller.draggingTab = nil
            controller.dragSourcePaneId = nil
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
            DispatchQueue.main.async {
                // Clear drag state
                controller.draggingTab = nil
                controller.dragSourcePaneId = nil

                // Handle both Data and String representations
                let string: String?
                if let data = item as? Data {
                    string = String(data: data, encoding: .utf8)
                } else if let nsString = item as? NSString {
                    string = nsString as String
                } else if let str = item as? String {
                    string = str
                } else {
                    string = nil
                }

                guard let string, let transfer = decodeTransfer(from: string) else {
                    return
                }

                // Same pane - reorder
                if transfer.sourcePaneId == pane.id.id {
                    guard let sourceIndex = pane.tabs.firstIndex(where: { $0.id == transfer.tab.id }) else {
                        return
                    }
                    withAnimation(.spring(duration: TabBarMetrics.reorderDuration, bounce: TabBarMetrics.reorderBounce)) {
                        pane.moveTab(from: sourceIndex, to: targetIndex)
                    }
                } else {
                    // Different pane - transfer
                    guard let sourcePaneId = controller.rootNode.allPaneIds.first(where: { $0.id == transfer.sourcePaneId }) else {
                        return
                    }
                    withAnimation(.spring(duration: TabBarMetrics.reorderDuration, bounce: TabBarMetrics.reorderBounce)) {
                        controller.moveTab(transfer.tab, from: sourcePaneId, to: pane.id, atIndex: targetIndex)
                    }
                }
            }
        }

        return true
    }

    func dropEntered(info: DropInfo) {
        dropTargetIndex = targetIndex
    }

    func dropExited(info: DropInfo) {
        if dropTargetIndex == targetIndex {
            dropTargetIndex = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    private func decodeTransfer(from string: String) -> TabTransferData? {
        guard let data = string.data(using: .utf8),
              let transfer = try? JSONDecoder().decode(TabTransferData.self, from: data) else {
            return nil
        }
        return transfer
    }
}
