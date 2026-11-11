import Bonsplit
import SwiftUI

extension Notification.Name {
    static let closeFritzBrowser = Self("closeFritzBrowser")
}

@MainActor @Observable
final class BrowserTabs: @preconcurrency BonsplitDelegate {
    let controller = BonsplitController(configuration: .init(
        allowSplits: false,
        allowCrossPaneTabMove: false,
        autoCloseEmptyPanes: false,
        appearance: .init(showSplitButtons: false)
    ))
    private var pages: [TabID: BrowserTab] = [:]
    private var isClosingAll = false

    init() {
        for id in controller.allTabIds { controller.closeTab(id) }
        controller.delegate = self
    }

    var selectedTab: BrowserTab? {
        guard let pane = controller.focusedPaneId,
              let tab = controller.selectedTab(inPane: pane) else { return nil }
        return pages[tab.id]
    }

    var titles: [String] {
        controller.allTabIds.map { title(for: $0) }
    }

    func updateTitles() {
        for id in controller.allTabIds {
            let title = title(for: id)
            if controller.tab(id)?.title != title { controller.updateTab(id, title: title) }
        }
    }

    private func title(for id: TabID) -> String {
        guard let title = pages[id]?.page.state.title, !title.isEmpty else { return "New Tab" }
        return title
    }

    func newTab() {
        guard let id = controller.createTab(title: "New Tab", icon: "globe") else { return }
        pages[id] = BrowserTab(id: id)
    }

    func closeTab(_ id: TabID) {
        controller.closeTab(id)
    }

    func closeOtherTabs(keeping id: TabID) {
        controller.selectTab(id)
        for other in controller.allTabIds where other != id { controller.closeTab(other) }
    }

    func closeTabsToRight(of id: TabID) {
        let ids = controller.allTabIds
        guard let index = ids.firstIndex(of: id) else { return }
        for other in ids.dropFirst(index + 1) { controller.closeTab(other) }
    }

    func hasTabsToRight(of id: TabID) -> Bool {
        guard let index = controller.allTabIds.firstIndex(of: id) else { return false }
        return index + 1 < controller.allTabIds.count
    }

    func closeAllTabs() {
        isClosingAll = true
        for id in controller.allTabIds { controller.closeTab(id) }
        isClosingAll = false
    }

    func splitTabBar(_ controller: BonsplitController, didCloseTab id: TabID, fromPane pane: PaneID) {
        pages.removeValue(forKey: id)?.page.close()
        if !isClosingAll && controller.allTabIds.isEmpty { newTab() }
    }
}

struct BrowserWindow: View {
    @State private var tabs = BrowserTabs()
    @State private var dataActions = BrowserDataActions()
    @State private var importing = false
    @State private var filling = false
    @State private var fillPage: BrowserPage?
    @FocusState private var addressFocused: Bool

    private var selectedTab: BrowserTab? {
        tabs.selectedTab
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            if let tab = selectedTab {
                navigationBar(tab)
                if let error = tab.page.state.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                if tab.page.state.isLoading { ProgressView().progressViewStyle(.linear) }
                BrowserSurface(page: tab.page).id(tab.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: FritzWindowStyle.cornerRadius))
            }
        }
        .padding(8)
        .frame(minWidth: 500, minHeight: 360)
        .fritzWindowBackground()
        .focusedSceneValue(\.browserActions, BrowserActions(
            newTab: newTab, closeTab: closeSelectedTab, focusAddress: { addressFocused = true },
            reload: { selectedTab?.page.reload() },
            previousTab: tabs.controller.selectPreviousTab,
            nextTab: tabs.controller.selectNextTab,
            importData: {
                guard !importing, !filling, !dataActions.busy else { return }
                dataActions.discover()
                importing = true
            },
            fillPassword: {
                guard !importing, !filling, !dataActions.busy else { return }
                if let page = selectedTab?.page {
                    fillPage = page
                    dataActions.loadAccounts(page: page)
                    filling = true
                }
            }
        ))
        .sheet(isPresented: $importing) { BrowserImportSheet(actions: dataActions) }
        .sheet(isPresented: $filling) {
            if let fillPage { BrowserPasswordSheet(actions: dataActions, page: fillPage) }
        }
        .onAppear {
            if tabs.controller.allTabIds.isEmpty { newTab() }
        }
        .onChange(of: tabs.titles, initial: true) { tabs.updateTitles() }
        .onChange(of: selectedTab?.id) {
            addressFocused = selectedTab?.page.state.url == nil
        }
        .onDisappear { dataActions.cancel(); tabs.closeAllTabs() }
        .onReceive(NotificationCenter.default.publisher(for: .closeFritzBrowser)) { _ in
            dataActions.cancel()
            tabs.closeAllTabs()
        }
    }

    private var tabBar: some View {
        BonsplitTabBar(controller: tabs.controller, createTab: newTab) { tab, _ in
            Button("Close Tab") { tabs.closeTab(tab.id) }
            Button("Close Other Tabs") { tabs.closeOtherTabs(keeping: tab.id) }
                .disabled(tabs.controller.allTabIds.count < 2)
            Button("Close Tabs to the Right") { tabs.closeTabsToRight(of: tab.id) }
                .disabled(!tabs.hasTabsToRight(of: tab.id))
        }
    }

    private func navigationBar(_ tab: BrowserTab) -> some View {
        @Bindable var tab = tab
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    navigationButton("Back", "chevron.left", action: tab.page.goBack)
                        .disabled(!tab.page.state.canGoBack)
                    navigationButton("Forward", "chevron.right", action: tab.page.goForward)
                        .disabled(!tab.page.state.canGoForward)
                }
                .frame(height: 30)
                .modifier(BrowserControlSurface())

                Button {
                    if tab.page.state.isLoading { tab.page.stop() }
                    else { tab.page.reload() }
                } label: {
                    Image(systemName: tab.page.state.isLoading ? "xmark" : "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .modifier(BrowserControlSurface())
                .disabled(!tab.page.state.isLoading && tab.page.state.url == nil)
                .accessibilityLabel(tab.page.state.isLoading ? "Stop Loading" : "Reload Page")
                .help(tab.page.state.isLoading ? "Stop Loading" : "Reload Page")
            }
            .foregroundStyle(.primary)
            .modifier(FritzGlassControlGroup())
            TextField("Website", text: $tab.address)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(1)
                .autocorrectionDisabled()
                .accessibilityLabel("Address")
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
                .background(Color(nsColor: .textBackgroundColor), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(addressFocused ? Color.accentColor : Color.primary.opacity(0.14),
                                      lineWidth: addressFocused ? 2 : 0.5)
                        .allowsHitTesting(false)
                }
                .focused($addressFocused)
                .onSubmit {
                    if tab.openAddress() { addressFocused = false }
                }
        }
        .padding(6)
        .background(Color(nsColor: BonsplitTabStyle.selectedBackground))
        .onChange(of: tab.page.state.url, initial: true) {
            if !addressFocused, let url = tab.page.state.url { tab.address = url.absoluteString }
        }
        .onChange(of: addressFocused) {
            if !addressFocused, let url = tab.page.state.url { tab.address = url.absoluteString }
        }
        .onChange(of: tab.id) {
            if !addressFocused, let url = tab.page.state.url { tab.address = url.absoluteString }
        }
    }

    private func navigationButton(_ title: String, _ icon: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.callout.weight(.medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }

    private func newTab() {
        tabs.newTab()
        addressFocused = true
    }

    private func closeSelectedTab() {
        if let tab = selectedTab { tabs.closeTab(tab.id) }
    }

}

private struct BrowserSurface: NSViewRepresentable {
    let page: BrowserPage

    func makeNSView(context: Context) -> NSView { page.view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct BrowserControlSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .background {
                    if reduceTransparency {
                        Capsule().fill(Color(nsColor: .controlBackgroundColor))
                    } else {
                        Capsule().fill(.thinMaterial)
                    }
                }
                .overlay {
                    Capsule().stroke(Color.primary.opacity(0.14), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
        }
    }
}

struct BrowserActions {
    let newTab: () -> Void
    let closeTab: () -> Void
    let focusAddress: () -> Void
    let reload: () -> Void
    let previousTab: () -> Void
    let nextTab: () -> Void
    let importData: () -> Void
    let fillPassword: () -> Void
}

extension FocusedValues {
    @Entry var browserActions: BrowserActions?
}

struct BrowserCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.browserActions) private var browser

    var body: some Commands {
        CommandMenu("Browser") {
            Button("Show Browser") { openWindow(id: "browser") }
                .keyboardShortcut("2")
            Divider()
            Button("New Tab") { browser?.newTab() }
                .keyboardShortcut("t")
                .disabled(browser == nil)
            Button("Close Tab") { browser?.closeTab() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(browser == nil)
            Divider()
            Button("Previous Tab") { browser?.previousTab() }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(browser == nil)
            Button("Next Tab") { browser?.nextTab() }
                .keyboardShortcut(.tab, modifiers: [.control])
                .disabled(browser == nil)
            Divider()
            Button("Import Cookies and Passwords…") { browser?.importData() }
                .disabled(browser == nil)
            Button("Fill Password…") { browser?.fillPassword() }
                .disabled(browser == nil)
            Divider()
            Button("Focus Address") { browser?.focusAddress() }
                .keyboardShortcut("l")
                .disabled(browser == nil)
            Button("Reload Page") { browser?.reload() }
                .keyboardShortcut("r")
                .disabled(browser == nil)
        }
    }
}
