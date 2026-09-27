import SwiftUI

/// Main entry point for the Bonsplit library
///
/// Usage:
/// ```swift
/// struct MyApp: View {
///     @State private var controller = BonsplitController()
///
///     var body: some View {
///         BonsplitView(controller: controller) { tab, paneId in
///             MyContentView(for: tab)
///                 .onTapGesture { controller.focusPane(paneId) }
///         } emptyPane: { paneId in
///             Text("Empty pane")
///         }
///     }
/// }
/// ```
public struct BonsplitView<Content: View, EmptyContent: View>: View {
    @Bindable private var controller: BonsplitController
    private let contentBuilder: (Tab, PaneID) -> Content
    private let emptyPaneBuilder: (PaneID) -> EmptyContent
    private let tabContextMenuBuilder: (Tab, PaneID) -> AnyView

    /// Initialize with a controller, content builder, empty pane builder, and tab context menu.
    /// - Parameters:
    ///   - controller: The BonsplitController managing the tab state
    ///   - content: A ViewBuilder closure that provides content for each tab. Receives the tab and pane ID.
    ///   - emptyPane: A ViewBuilder closure that provides content for empty panes
    ///   - tabContextMenu: A ViewBuilder closure that provides contextual actions for each tab.
    public init<TabContextMenu: View>(
        controller: BonsplitController,
        @ViewBuilder content: @escaping (Tab, PaneID) -> Content,
        @ViewBuilder emptyPane: @escaping (PaneID) -> EmptyContent,
        @ViewBuilder tabContextMenu: @escaping (Tab, PaneID) -> TabContextMenu
    ) {
        self.controller = controller
        self.contentBuilder = content
        self.emptyPaneBuilder = emptyPane
        self.tabContextMenuBuilder = { tab, pane in
            AnyView(tabContextMenu(tab, pane))
        }
    }

    public var body: some View {
        SplitViewContainer(
            contentBuilder: { tabItem, paneId in
                contentBuilder(Tab(from: tabItem), PaneID(id: paneId.id))
            },
            emptyPaneBuilder: { internalPaneId in
                emptyPaneBuilder(PaneID(id: internalPaneId.id))
            },
            tabContextMenuBuilder: { tabItem, internalPaneId in
                tabContextMenuBuilder(
                    Tab(from: tabItem),
                    PaneID(id: internalPaneId.id)
                )
            },
            showSplitButtons: controller.configuration.allowSplits && controller.configuration.appearance.showSplitButtons,
            contentViewLifecycle: controller.configuration.contentViewLifecycle,
            onGeometryChange: { [weak controller] isDragging in
                controller?.notifyGeometryChange(isDragging: isDragging)
            }
        )
        .environment(controller)
        .environment(controller.internalController)
    }
}

// MARK: - Initializer without a tab context menu

extension BonsplitView {
    /// Initialize with a controller, content builder, and empty pane builder.
    public init(
        controller: BonsplitController,
        @ViewBuilder content: @escaping (Tab, PaneID) -> Content,
        @ViewBuilder emptyPane: @escaping (PaneID) -> EmptyContent
    ) {
        self.init(
            controller: controller,
            content: content,
            emptyPane: emptyPane,
            tabContextMenu: { _, _ in EmptyView() }
        )
    }
}

// MARK: - Convenience initializer with default empty view

extension BonsplitView where EmptyContent == DefaultEmptyPaneView {
    /// Initialize with a controller and content builder, using the default empty pane view
    /// - Parameters:
    ///   - controller: The BonsplitController managing the tab state
    ///   - content: A ViewBuilder closure that provides content for each tab. Receives the tab and pane ID.
    public init(
        controller: BonsplitController,
        @ViewBuilder content: @escaping (Tab, PaneID) -> Content
    ) {
        self.controller = controller
        self.contentBuilder = content
        self.emptyPaneBuilder = { _ in DefaultEmptyPaneView() }
        self.tabContextMenuBuilder = { _, _ in AnyView(EmptyView()) }
    }
}

extension BonsplitView where EmptyContent == DefaultEmptyPaneView {
    /// Initialize with a controller, content builder, and tab context menu,
    /// using the default empty pane view.
    public init<TabContextMenu: View>(
        controller: BonsplitController,
        @ViewBuilder content: @escaping (Tab, PaneID) -> Content,
        @ViewBuilder tabContextMenu: @escaping (Tab, PaneID) -> TabContextMenu
    ) {
        self.init(
            controller: controller,
            content: content,
            emptyPane: { _ in DefaultEmptyPaneView() },
            tabContextMenu: tabContextMenu
        )
    }
}

/// Default view shown when a pane has no tabs
public struct DefaultEmptyPaneView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("No Open Tabs")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
