import FritzUI
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
        FritzSettingsTab(rawValue: settings.selectedTab) ?? .general
    }
    var isCreatingProject = false

    init() {
        let agent = AgentClient()
        self.agent = agent
        workspace = WorkspaceStore(agent: agent)
        providers = ProviderStore(agent: agent, database: workspace.database, modelCatalog: workspace.modelCatalog)
        settings = AppSettings(database: workspace.database)
        localModels = LocalModelRuntimeStore(agent: agent, database: workspace.database)
    }
    func newThread() {
        if let project = workspace.selectedProject ?? workspace.projects.first(where: { workspace.isAvailable($0) }) {
            workspace.createThread(in: project.id)
        } else { isCreatingProject = true }
    }
    func selectSettings(_ tab: FritzSettingsTab) {
        settings.selectedTab = tab.rawValue
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidUpdate(_:)),
            name: NSWindow.didUpdateNotification, object: nil
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

    @objc private func windowDidUpdate(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.isSheet, window.preventsApplicationTerminationWhenModal else { return }
        // SwiftUI can finalize a fitted sheet's modal policy after it becomes key.
        DispatchQueue.main.async { [weak window] in
            guard let window, window.isSheet, window.preventsApplicationTerminationWhenModal else { return }
            window.preventsApplicationTerminationWhenModal = false
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NotificationCenter.default.post(name: .closeFritzBrowser, object: nil)
        #if FRITZ_CHROMIUM
        let finished = FritzChromiumApplication.finishBrowserShutdown {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return finished ? .terminateNow : .terminateLater
        #else
        return .terminateNow
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        FritzState.shared.workspace.shutdown()
        FritzState.shared.localModels.stopAll()
        FritzState.shared.agent.stop()
    }
}

@main
@MainActor
enum FritzMain {
    static func main() {
        #if FRITZ_CHROMIUM
        FritzChromiumApplication.prepare()
        let directory = FritzPaths.data.appendingPathComponent("Chromium", isDirectory: true)
        _ = FritzChromiumApplication.startBrowser(dataDirectory: directory)
        #endif
        FritzApp.main()
    }
}

struct FritzApp: App {
    @NSApplicationDelegateAdaptor(FritzAppDelegate.self) private var delegate
    @State private var state = FritzState.shared
    @StateObject private var updater = AppUpdater(updateChannel: AppUpdateChannel(rawValue: FritzState.shared.settings.updateChannel) ?? .release)
    @Environment(\.openWindow) private var openWindow

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
                    .disabled(!state.workspace.projects.isEmpty && !state.workspace.canCreateThread)
                Divider()
                Button("New Local Model") { openWindow(id: "local-models") }
                Button("New Remote Model") { openWindow(id: "remote-models") }
            }
            CommandMenu("Chat") {
                Button("Show Chat") { openWindow(id: "main") }.keyboardShortcut("1")
                Button("Stop Response") { state.workspace.selectedChat?.stop() }.keyboardShortcut(".")
                    .disabled(state.workspace.selectedChat?.isResponding != true)
            }
            CommandMenu("Models") {
                Button("Local Models…") { openWindow(id: "local-models") }
                Button("Remote Models…") { openWindow(id: "remote-models") }
            }
        }

        Window("Local Models", id: "local-models") {
            ModelsCatalogView(store: state.providers, runtime: state.localModels, location: .local)
                .frame(minWidth: 640, minHeight: 400)
        }
        .defaultSize(width: 900, height: 620)
        .defaultLaunchBehavior(.suppressed)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))

        Window("Remote Models", id: "remote-models") {
            ModelsCatalogView(store: state.providers, runtime: state.localModels, location: .remote)
                .frame(minWidth: 800, minHeight: 520)
        }
        .defaultSize(width: 900, height: 620)
        .defaultLaunchBehavior(.suppressed)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))

        Window("Browser", id: "browser") {
            BrowserWindow()
        }
        .defaultSize(width: 1050, height: 750)
        .defaultLaunchBehavior(.suppressed)
        .fritzWindowStyle()
        .commands { BrowserCommands() }

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
    @State private var isRightPanelPresented = false
    @State private var chatHeaderBottom: CGFloat = 0

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            ProjectsSidebar(workspace: state.workspace)
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                if let error = state.workspace.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).textSelection(.enabled).padding(12)
                }
                if let project = state.workspace.selectedProject, !state.workspace.isAvailable(project) {
                    ContentUnavailableView("Project Folder Unavailable", systemImage: "folder.badge.questionmark",
                                           description: Text("Use Fix in the sidebar to reconnect its folder."))
                } else if let thread = state.workspace.selectedThread, let chat = state.workspace.selectedChat {
                    let chatView = ChatView(store: chat, providers: state.providers,
                                            localModels: state.localModels,
                                            openModels: { openWindow(id: $0 == .local ? "local-models" : "remote-models") },
                                            headerBottom: chatHeaderBottom)
                        .id(thread.id)
                    Group {
                        if #available(macOS 26.0, *) {
                            GeometryReader { geometry in
                                // Extend real transcript content behind the toolbar;
                                // reserve its inset for the sharp foreground title.
                                chatView
                                    .safeAreaInset(edge: .top, spacing: 0) {
                                        chatHeader(projectName: state.workspace.selectedProject?.name ?? "",
                                                   threadTitle: thread.title)
                                            .padding(.top, geometry.safeAreaInsets.top)
                                            .onGeometryChange(for: CGFloat.self) {
                                                $0.frame(in: .global).maxY
                                            } action: { chatHeaderBottom = $0 }
                                    }
                                    .scrollEdgeEffectHidden(for: .top)
                                    .ignoresSafeArea(.container, edges: .top)
                                    .clipShape(RoundedRectangle(cornerRadius: FritzWindowStyle.cornerRadius, style: .continuous))
                            }
                        } else {
                            chatView
                                .safeAreaInset(edge: .top, spacing: 0) {
                                    chatHeader(projectName: state.workspace.selectedProject?.name ?? "",
                                               threadTitle: thread.title)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: FritzWindowStyle.cornerRadius, style: .continuous))
                        }
                    }
                    .background(FritzWindowStyle.workspaceBackground)
                } else {
                    FritzWindowStyle.workspaceBackground
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, 4).padding(.trailing, 8).padding(.bottom, 8)
            .background { FritzWorkspaceBackground().ignoresSafeArea() }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .inspector(isPresented: $isRightPanelPresented) {
            WorkspaceRightPanel {
                isRightPanelPresented = false
            }
            .inspectorColumnWidth(min: 220, ideal: 260, max: 400)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                WindowNewItemMenu(canCreateThread: state.workspace.canCreateThread,
                                  createProject: { state.isCreatingProject = true },
                                  createThread: state.newThread,
                                  createRemoteModel: { openWindow(id: "remote-models") },
                                  createLocalModel: { openWindow(id: "local-models") })
            }
            ToolbarItemGroup(placement: .principal) {
                Button("Local Models", systemImage: "cpu") { openWindow(id: "local-models") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(FritzButtonStyle(.toolbar))
                    .help("Local Models")
                Button("Remote Models", systemImage: "network") { openWindow(id: "remote-models") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(FritzButtonStyle(.toolbar))
                    .help("Remote Models")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                newThreadToolbarButton
                Button("Toggle Right Panel", systemImage: "sidebar.right") {
                    isRightPanelPresented.toggle()
                }
                .labelStyle(.iconOnly)
                .help(isRightPanelPresented ? "Hide Right Panel" : "Show Right Panel")
                .accessibilityValue(isRightPanelPresented ? "Shown" : "Hidden")
            }
        }
        .fritzWindowBackground()
        .frame(minWidth: 900, minHeight: 620)
        .sheet(isPresented: $state.isCreatingProject) { NewProjectSheet(workspace: state.workspace) }
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
    }

    private var newThreadToolbarButton: some View {
        Button("New Chat", systemImage: "square.and.pencil", action: state.newThread)
            .labelStyle(.iconOnly).help("New Chat (⌘N)")
            .disabled(!state.workspace.canCreateThread)
    }


}
