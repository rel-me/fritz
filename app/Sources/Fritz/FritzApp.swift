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
    var isBrowserPresented = false
    var isCreatingProject = false

    init() {
        let agent = AgentClient()
        self.agent = agent
        workspace = WorkspaceStore(agent: agent)
        providers = ProviderStore(agent: agent, database: workspace.database, modelCatalog: workspace.modelCatalog)
        settings = workspace.appSettings
        localModels = LocalModelRuntimeStore(agent: agent, database: workspace.database)
    }
    func newThread() {
        guard workspace.canSave, !workspace.isEditing else { return }
        if let project = workspace.selectedProject ?? workspace.projects.first(where: { workspace.isAvailable($0) }) {
            Task { await workspace.createThread(in: project.id) }
        } else { isCreatingProject = true }
    }
    func selectSettings(_ tab: FritzSettingsTab) {
        settings.selectedTab = tab.rawValue
    }

}

@MainActor final class FritzAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Use the original silhouette where AppKit lets the running app set its own icon.
        if #available(macOS 26.0, *),
           let iconURL = Bundle.main.url(forResource: "FritzRaven", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

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

    private enum Termination {
        case idle, shuttingDown, ready
    }

    private var termination = Termination.idle

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch termination {
        case .ready: return .terminateNow
        case .shuttingDown: return .terminateCancel
        case .idle: termination = .shuttingDown
        }
        NotificationCenter.default.post(name: .closeFritzBrowser, object: nil)
        Task {
            await FritzState.shared.workspace.shutdown()
            #if FRITZ_CHROMIUM
            if !FritzChromiumApplication.finishBrowserShutdown({
                self.terminateAfterShutdown(sender)
            }) { return }
            #endif
            terminateAfterShutdown(sender)
        }
        // A nested AppKit termination loop can suspend Chromium's message pump
        // while browser close callbacks are still pending.
        return .terminateCancel
    }

    private func terminateAfterShutdown(_ sender: NSApplication) {
        termination = .ready
        sender.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
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
            FritzWorkspaceView(state: state)
                .task {
                    state.agent.start()
                    state.localModels.startService()
                    await state.providers.refresh()
                    await state.localModels.startAtAppLaunch(state.providers.connections)
                }
        }
        .defaultSize(width: 1080, height: 760)
        .fritzWindowStyle()
        .commands {
            CommandGroup(replacing: .appInfo) {
                let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Fritz"
                Button("About \(appName)") {
                    guard let icon = NSApp.applicationIconImage.copy() as? NSImage else { return }
                    icon.isTemplate = true
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationIcon: icon])
                }
                CheckForUpdatesCommand(updater: updater)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { state.isCreatingProject = true; openWindow(id: "main") }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Chat") { state.newThread(); openWindow(id: "main") }.keyboardShortcut("n")
                    .disabled(!state.workspace.canSave || state.workspace.isEditing || (!state.workspace.projects.isEmpty && !state.workspace.canCreateThread))
                Divider()
                Button("New Local Model") { openWindow(id: "local-models") }
                Button("New Remote Model") { openWindow(id: "remote-models") }
            }
            CommandGroup(after: .toolbar) {
                Button(state.settings.showsStatusBar ? "Hide Status Bar" : "Show Status Bar") {
                    state.settings.showsStatusBar.toggle()
                }
            }
            CommandMenu("Chat") {
                Button("Show Chat") { openWindow(id: "main") }.keyboardShortcut("1")
                Button("Stop Response") { state.workspace.selectedChat?.stopByUser() }.keyboardShortcut(".")
                    .disabled(state.workspace.selectedChat?.isResponding != true)
            }
            CommandMenu("Models") {
                Button("Local Models…") { openWindow(id: "local-models") }
                Button("Remote Models…") { openWindow(id: "remote-models") }
            }
        }
        .commands {
            BrowserCommands {
                state.isBrowserPresented = true
                openWindow(id: "main")
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
    @State private var browserTabs = BrowserTabs()
    @State private var browserOpeningID = 0
    @State private var workspaceWidth: CGFloat = 900
    @State private var chatHeaderFrame: CGRect = .zero

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            ProjectsSidebar(workspace: state.workspace)
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            let trailingInset: CGFloat = 8
            VStack(spacing: 0) {
                if let error = state.workspace.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).textSelection(.enabled).padding(12)
                }
                if let project = state.workspace.selectedProject,
                   let thread = state.workspace.selectedThread, let chat = state.workspace.selectedChat {
                    let chatView = ChatView(store: chat, providers: state.providers,
                                            localModels: state.localModels,
                                            localChatStatuses: state.workspace.localChatStatuses,
                                            openModels: { openWindow(id: $0 == .local ? "local-models" : "remote-models") },
                                            headerFrame: chatHeaderFrame,
                                            contentTrailingInset: state.isBrowserPresented ? 0 : trailingInset,
                                            isProjectFolderAvailable: state.workspace.isAvailable(project),
                                            isArchived: thread.isArchived)
                        .id(thread.id)
                    Group {
                        if #available(macOS 26.0, *) {
                            GeometryReader { geometry in
                                // Extend real transcript content behind the toolbar;
                                // reserve its inset for the sharp foreground title.
                                chatView
                                    .safeAreaInset(edge: .top, spacing: 0) {
                                        chatHeader(projectName: project.name,
                                                   threadTitle: thread.title)
                                            .padding(.top, geometry.safeAreaInsets.top)
                                            .onGeometryChange(for: CGRect.self) {
                                                $0.frame(in: .global)
                                            } action: { chatHeaderFrame = $0 }
                                    }
                                    .scrollEdgeEffectHidden(for: .top)
                                    .clipShape(RoundedRectangle(cornerRadius: FritzWindowStyle.cornerRadius, style: .continuous))
                                    .ignoresSafeArea(.container, edges: .top)
                            }
                        } else {
                            chatView
                                .safeAreaInset(edge: .top, spacing: 0) {
                                    chatHeader(projectName: project.name,
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
            .padding(.leading, 4)
            .padding(.trailing, state.isBrowserPresented ? trailingInset : 0)
            .padding(.bottom, 8)
            .background { FritzWorkspaceBackground().ignoresSafeArea() }
        }
        .onDisappear { browserTabs.closeAllTabs() }
        .onReceive(NotificationCenter.default.publisher(for: .closeFritzBrowser)) { _ in
            browserTabs.closeAllTabs()
        }
        .navigationSplitViewStyle(.prominentDetail)
        .onChange(of: state.isBrowserPresented, initial: true) { _, isPresented in
            if isPresented {
                browserOpeningID += 1
            }
        }
        .inspector(isPresented: $state.isBrowserPresented) {
            WorkspaceRightPanel(tabs: browserTabs)
                .background(BrowserInspectorSizing(openingID: browserOpeningID))
                .inspectorColumnWidth(min: 320, ideal: 320, max: max(320, workspaceWidth))
        }
        .transaction(value: state.isBrowserPresented) { transaction in
            transaction.disablesAnimations = true
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
            workspaceWidth = $0
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
                Button("Toggle Browser", systemImage: "sidebar.right") {
                    state.isBrowserPresented.toggle()
                }
                .labelStyle(.iconOnly)
                .help(state.isBrowserPresented ? "Hide Browser" : "Show Browser")
                .accessibilityValue(state.isBrowserPresented ? "Shown" : "Hidden")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if state.settings.showsStatusBar {
                let models = activeLocalModels
                if !models.isEmpty { FritzStatusBar(models: models) }
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

    private var activeLocalModels: [LocalModelStatus] {
        var models: [String: LocalModelStatus] = [:]
        let resident = state.localModels.sessions.compactMap { id, session in
            LocalModelStatus(id: id, session: session)
        }
        for model in resident + state.workspace.localChatStatuses {
            if let current = models[model.id], current.phase.rawValue >= model.phase.rawValue { continue }
            models[model.id] = model
        }
        return models.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
}

struct LocalModelStatus {
    enum Phase: Int {
        case stopping, starting, running

        var title: String {
            switch self {
            case .starting: "Starting"
            case .running: "Running"
            case .stopping: "Stopping"
            }
        }
    }

    let id: String
    let name: String
    var phase: Phase
    var loadProgress: Double?

    init(id: String, name: String, phase: Phase, loadProgress: Double? = nil) {
        self.id = id
        self.name = name
        self.phase = phase
        self.loadProgress = loadProgress
    }

    var title: String {
        guard phase == .starting else { return phase.title }
        guard let loadProgress else { return "Starting…" }
        if loadProgress >= 1 { return "Preparing context…" }
        return "Loading weights \(loadProgress.formatted(.percent.rounded(rule: .down)))"
    }

    init?(id: String, session: ModelsRuntimeSession) {
        let phase: Phase
        switch session.status {
        case .starting: phase = .starting
        case .running: phase = .running
        case .stopping: phase = .stopping
        case .stopped, .failed: return nil
        }
        self.init(id: id, name: NativeModelDescriptor.catalog.first { $0.id == id }?.name ?? id,
                  phase: phase, loadProgress: session.loadProgress)
    }
}

private struct FritzStatusBar: View {
    let models: [LocalModelStatus]
    @State private var usedMemory: UInt64?

    private var modelSummary: String {
        models.map { "\($0.name) · \($0.title)" }.joined(separator: "  |  ")
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                Label(modelSummary, systemImage: "cpu")
                    .lineLimit(1)
                    .help(modelSummary)
                Spacer(minLength: 8)
                if let usedMemory {
                    Label("Memory \(gibibytes(usedMemory)) of \(gibibytes(ProcessInfo.processInfo.physicalMemory)) GiB",
                          systemImage: "memorychip")
                        .monospacedDigit()
                        .fixedSize()
                        .help("System memory used")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .background(FritzWindowStyle.workspaceBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status Bar")
        .task {
            while !Task.isCancelled {
                usedMemory = ModelsLocalRuntime.usedMemoryBytes
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func gibibytes(_ bytes: UInt64) -> String {
        (Double(bytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(0...1)))
    }
}
