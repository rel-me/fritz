import FritzUpdates
import Fritz
import SwiftUI

@MainActor @Observable final class FritzState {
    static let shared = FritzState()
    let agent: AgentClient
    let providers: ProviderStore
    let workspace: WorkspaceStore
    let localModels: LocalModelRuntimeStore
    let settings: AppSettings
    var settingsTab: FritzSettingsTab {
        settings.selectedTab == "localModels" ? .providers : FritzSettingsTab(rawValue: settings.selectedTab) ?? .general
    }
    var isCreatingProject = false
    var editor: ProviderEditorSelection?
    var showsLocalModelDownload = false

    init() {
        let agent = AgentClient()
        self.agent = agent
        workspace = WorkspaceStore(agent: agent)
        providers = ProviderStore(agent: agent, database: workspace.database)
        settings = AppSettings(database: workspace.database)
        localModels = LocalModelRuntimeStore(agent: agent, database: workspace.database)
    }
    func newThread() {
        if let project = workspace.selectedProject ?? workspace.projects.first {
            workspace.createThread(in: project.id)
        } else { isCreatingProject = true }
    }
    func selectSettings(_ tab: FritzSettingsTab) {
        settings.selectedTab = tab.rawValue
    }
    func newLocalModel() {
        selectSettings(.providers)
        showsLocalModelDownload = true
    }
}

@MainActor final class FritzAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillBeginSheet(_:)),
            name: NSWindow.willBeginSheetNotification, object: nil
        )
        for window in NSApp.windows {
            window.preventsApplicationTerminationWhenModal = false
        }
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        (notification.object as? NSWindow)?.preventsApplicationTerminationWhenModal = false
    }

    @objc private func windowWillBeginSheet(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        window.preventsApplicationTerminationWhenModal = false
        // The sheet is attached after this notification is sent.
        DispatchQueue.main.async {
            window.attachedSheet?.preventsApplicationTerminationWhenModal = false
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        FritzState.shared.workspace.shutdown()
        FritzState.shared.localModels.stopAll()
        FritzState.shared.agent.stop()
    }
}

@main struct FritzApp: App {
    @NSApplicationDelegateAdaptor(FritzAppDelegate.self) private var delegate
    @State private var state = FritzState.shared
    @StateObject private var updater = AppUpdater(updateChannel: AppUpdateChannel(rawValue: FritzState.shared.settings.updateChannel) ?? .release)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    init() {
        (AppAppearance(rawValue: FritzState.shared.settings.appearance) ?? .system).apply(to: NSApplication.shared)
    }

    var body: some Scene {
        Window("Fritz", id: "main") {
            Group {
                if updater.allowsAppUse {
                    FritzWorkspaceView(state: state)
                } else if let version = updater.requiredVersion {
                    ContentUnavailableView {
                        Label("Fritz \(version) is required", systemImage: "arrow.down.circle")
                    } description: {
                        Text("Install the required update to continue.")
                    } actions: {
                        Button("Update Fritz") { updater.checkForUpdates() }
                    }
                } else {
                    ProgressView("Checking for updates…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
                .task {
                    updater.checkForUpdatesAtStartup()
                }
                .task(id: updater.allowsAppUse) {
                    guard updater.allowsAppUse else { return }
                    state.agent.start()
                    state.localModels.startService()
                    await state.providers.refresh()
                    await state.localModels.startAtAppLaunch(state.providers.connections)
                }
        }
        .defaultSize(width: 1080, height: 760)
        .fritzWindowStyle()
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updater: updater)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { state.isCreatingProject = true; openWindow(id: "main") }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Chat") { state.newThread(); openWindow(id: "main") }.keyboardShortcut("n")
                Divider()
                Button("New Model") { state.editor = ProviderEditorSelection(); openWindow(id: "main") }
                Button("New Local Model") { state.newLocalModel(); openSettings() }
            }
            CommandMenu("Chat") {
                Button("Show Chat") { openWindow(id: "main") }.keyboardShortcut("1")
                Button("Stop Response") { state.workspace.selectedChat?.stop() }.keyboardShortcut(".")
                    .disabled(state.workspace.selectedChat?.isResponding != true)
            }
            CommandMenu("Models") {
                Button("Models…") { state.selectSettings(.providers); openSettings() }
            }
        }

        Settings {
            FritzSettingsView(state: state, updater: updater)
        }
        .defaultSize(width: 900, height: 580)
        .fritzWindowStyle()
    }
}

private struct FritzWorkspaceView: View {
    @Bindable var state: FritzState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isRightPanelPresented = false
    @State private var rightPanelWidth: CGFloat = 260
    @State private var rightPanelToggleWidth: CGFloat = 24

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            ProjectsSidebar(workspace: state.workspace)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                if let error = state.workspace.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).textSelection(.enabled).padding(12)
                }
                if let thread = state.workspace.selectedThread, let chat = state.workspace.selectedChat {
                    let chatView = ChatView(store: chat, providers: state.providers,
                                            openProviders: openProviders,
                                            addProvider: { state.editor = ProviderEditorSelection() })
                        .id(thread.id)
                    Group {
                        if #available(macOS 26.0, *) {
                            chatView
                                .safeAreaBar(edge: .top, spacing: 0) {
                                    chatHeader(projectName: state.workspace.selectedProject?.name ?? "",
                                               threadTitle: thread.title)
                                }
                                .scrollEdgeEffectStyle(.soft, for: .top)
                        } else {
                            chatView
                                .safeAreaInset(edge: .top, spacing: 0) {
                                    chatHeader(projectName: state.workspace.selectedProject?.name ?? "",
                                               threadTitle: thread.title)
                                }
                        }
                    }
                    .background(FritzWindowStyle.workspaceBackground)
                } else {
                    FritzWindowStyle.workspaceBackground
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: FritzWindowStyle.cornerRadius, style: .continuous))
            .padding(.leading, 4).padding(.trailing, 8).padding(.bottom, 8)
            .background { FritzWorkspaceBackground().ignoresSafeArea() }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .inspector(isPresented: $isRightPanelPresented) {
            WorkspaceRightPanel {
                isRightPanelPresented = false
            }
            .inspectorColumnWidth(min: 220, ideal: 260, max: 400)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rightPanelWidth = $0 }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                WindowNewItemMenu(canCreateThread: !state.workspace.projects.isEmpty,
                                  createProject: { state.isCreatingProject = true },
                                  createThread: state.newThread,
                                  createProvider: { state.editor = ProviderEditorSelection() },
                                  createLocalModel: { state.newLocalModel(); openSettings() })
            }
            ToolbarItem(placement: .principal) {
                Button("Models", systemImage: "cpu") { openProviders() }
                    .labelStyle(.iconOnly).buttonStyle(FritzButtonStyle(.toolbar)).help("Models")
            }
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) {
                    newThreadToolbarButton
                        .padding(.trailing, newChatToolbarTrailingSpace)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) {
                    newThreadToolbarButton
                        .padding(.trailing, newChatToolbarTrailingSpace)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Toggle Right Panel", systemImage: "sidebar.right") {
                    isRightPanelPresented.toggle()
                }
                .labelStyle(.iconOnly).buttonStyle(FritzButtonStyle(.toolbar))
                .foregroundStyle(isRightPanelPresented ? Color.accentColor : .secondary)
                .help(isRightPanelPresented ? "Hide Right Panel" : "Show Right Panel")
                .accessibilityValue(isRightPanelPresented ? "Shown" : "Hidden")
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rightPanelToggleWidth = $0 }
            }
        }
        .fritzWindowBackground()
        .frame(minWidth: 900, minHeight: 620)
        .sheet(isPresented: $state.isCreatingProject) { NewProjectSheet(workspace: state.workspace) }
        .sheet(item: $state.editor) { ProviderEditor(store: state.providers, localModels: state.localModels, existing: $0.connection) }
    }

    private func chatHeader(projectName: String, threadTitle: String) -> some View {
        HStack(spacing: 8) {
            Text(projectName).foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            Text(threadTitle).lineLimit(1).truncationMode(.tail)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background {
            if !reduceTransparency, #unavailable(macOS 26.0) {
                Rectangle().fill(.ultraThinMaterial)
            }
        }
    }

    // The toggle occupies the trailing toolbar slot. Reserve the rest of the
    // native inspector's measured width so New Chat follows the chat divider.
    private var newChatToolbarTrailingSpace: CGFloat {
        isRightPanelPresented ? max(0, rightPanelWidth - rightPanelToggleWidth - 12) : 0
    }

    private var newThreadToolbarButton: some View {
        Button("New Chat", systemImage: "square.and.pencil", action: state.newThread)
            .buttonStyle(FritzButtonStyle(.toolbar)).help("New Chat (⌘N)")
            .disabled(state.workspace.projects.isEmpty || !state.workspace.canSave)
    }

    private func openProviders() {
        state.selectSettings(.providers)
        openSettings()
    }
}
