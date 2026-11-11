import SwiftUI

extension Notification.Name {
    static let closeFritzBrowser = Self("closeFritzBrowser")
}

struct BrowserWindow: View {
    @State private var tabs: [BrowserTab] = []
    @State private var selectedID: BrowserTab.ID?
    @FocusState private var addressFocused: Bool

    private var selectedTab: BrowserTab? {
        tabs.first { $0.id == selectedID }
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
            reload: { selectedTab?.page.reload() }
        ))
        .onAppear {
            if tabs.isEmpty { newTab() }
        }
        .onDisappear(perform: closeAllTabs)
        .onReceive(NotificationCenter.default.publisher(for: .closeFritzBrowser)) { _ in
            closeAllTabs()
        }
    }

    private var tabBar: some View {
        HStack {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(tabs) { tab in
                        HStack(spacing: 2) {
                            Button {
                                selectedID = tab.id
                            } label: {
                                Text(tab.page.state.title.isEmpty ? "New Tab" : tab.page.state.title)
                                    .lineLimit(1)
                                    .frame(maxWidth: 160)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selectedID == tab.id ? .isSelected : [])
                            Button {
                                closeTab(tab)
                            } label: {
                                Image(systemName: "xmark").font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Close Tab")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(selectedID == tab.id ? Color.primary.opacity(0.1) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
            .scrollIndicators(.hidden)
            Button(action: newTab) { Image(systemName: "plus") }
                .accessibilityLabel("New Tab")
                .help("New Tab")
        }
        .padding(.horizontal, 4)
    }

    private func navigationBar(_ tab: BrowserTab) -> some View {
        @Bindable var tab = tab
        return HStack {
            control("Back", "chevron.left", action: tab.page.goBack)
                .disabled(!tab.page.state.canGoBack)
            control("Forward", "chevron.right", action: tab.page.goForward)
                .disabled(!tab.page.state.canGoForward)
            if tab.page.state.isLoading {
                control("Stop", "xmark", action: tab.page.stop)
            } else {
                control("Reload", "arrow.clockwise", action: tab.page.reload)
                    .disabled(tab.page.state.url == nil)
            }
            TextField("Address", text: $tab.address)
                .focused($addressFocused)
                .onSubmit {
                    if tab.openAddress() { addressFocused = false }
                }
        }
        .padding(6)
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

    private func control(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }
            .accessibilityLabel(title)
            .help(title)
    }

    private func newTab() {
        let tab = BrowserTab()
        tabs.append(tab)
        selectedID = tab.id
        addressFocused = true
    }

    private func closeAllTabs() {
        for tab in tabs { tab.page.close() }
        tabs.removeAll()
        selectedID = nil
    }

    private func closeSelectedTab() {
        if let tab = selectedTab { closeTab(tab) }
    }

    private func closeTab(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.page.close()
        tabs.remove(at: index)
        if tabs.isEmpty { newTab() }
        else if selectedID == tab.id { selectedID = tabs[min(index, tabs.count - 1)].id }
    }
}

private struct BrowserSurface: NSViewRepresentable {
    let page: BrowserPage

    func makeNSView(context: Context) -> NSView { page.view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct BrowserActions {
    let newTab: () -> Void
    let closeTab: () -> Void
    let focusAddress: () -> Void
    let reload: () -> Void
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
            Button("Focus Address") { browser?.focusAddress() }
                .keyboardShortcut("l")
                .disabled(browser == nil)
            Button("Reload Page") { browser?.reload() }
                .keyboardShortcut("r")
                .disabled(browser == nil)
        }
    }
}
