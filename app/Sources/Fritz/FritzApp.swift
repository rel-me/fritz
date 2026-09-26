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
    var editor: ProviderEditorSelection?

    init() {
        let agent = AgentClient()
        self.agent = agent
        workspace = WorkspaceStore(agent: agent)
        providers = ProviderStore(agent: agent, database: workspace.database)
        settings = AppSettings(database: workspace.database)
        localModels = LocalModelRuntimeStore(agent: agent)
    }
    func newThread() {
        if let project = workspace.selectedProject ?? workspace.projects.first {
            workspace.createThread(in: project.id)
        } else { isCreatingProject = true }
    }
    func selectSettings(_ tab: FritzSettingsTab) {
        settings.selectedTab = tab.rawValue
    }
}

@MainActor final class FritzAppDelegate: NSObject, NSApplicationDelegate {
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
                    await state.providers.refresh()
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
                Button("New Thread") { state.newThread(); openWindow(id: "main") }.keyboardShortcut("n")
            }
            CommandMenu("Chat") {
                Button("Show Chat") { openWindow(id: "main") }.keyboardShortcut("1")
                Button("Stop Response") { state.workspace.selectedChat?.stop() }.keyboardShortcut(".")
                    .disabled(state.workspace.selectedChat?.isResponding != true)
            }
            CommandMenu("Models") {
                Button("Local Models…") { state.selectSettings(.localModels); openSettings() }
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
    @State private var isRightPanelPresented = false
    @State private var isBottomPanelPresented = false

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            ProjectsSidebar(workspace: state.workspace)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        if let error = state.workspace.error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange).textSelection(.enabled).padding(12)
                        }
                        if let thread = state.workspace.selectedThread, let chat = state.workspace.selectedChat {
                            VStack(spacing: 0) {
                                HStack(spacing: 8) {
                                    Text(state.workspace.selectedProject?.name ?? "").foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                    Text(thread.title).lineLimit(1).truncationMode(.tail)
                                    Spacer()
                                }
                                .font(.callout)
                                .padding(.horizontal, 20).padding(.vertical, 14)
                                ChatView(store: chat, providers: state.providers,
                                         openProviders: { openProviders() },
                                         addProvider: { state.editor = ProviderEditorSelection() })
                                    .id(thread.id)
                            }
                            .background(FritzWindowStyle.contentBackground)
                        } else {
                            FritzWindowStyle.contentBackground
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if isRightPanelPresented {
                        Rectangle().fill(.separator).frame(width: 0.5)
                        WorkspacePlaceholderPanel(title: "Right Panel", systemImage: "sidebar.right") {
                            isRightPanelPresented = false
                        }
                        .frame(width: 260)
                    }
                }

                if isBottomPanelPresented {
                    Rectangle().fill(.separator).frame(height: 0.5)
                    WorkspacePlaceholderPanel(title: "Bottom Panel", systemImage: "rectangle.bottomthird.inset.filled") {
                        isBottomPanelPresented = false
                    }
                    .frame(height: 190)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: FritzWindowStyle.cornerRadius, style: .continuous))
            .padding(.leading, 4).padding(.trailing, 8).padding(.bottom, 8)
            .background { FritzWorkspaceBackground().ignoresSafeArea() }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                WindowNewItemMenu(canCreateThread: !state.workspace.projects.isEmpty,
                                  createProject: { state.isCreatingProject = true },
                                  createThread: state.newThread,
                                  createProvider: { state.editor = ProviderEditorSelection() })
            }
            ToolbarItem(placement: .principal) {
                Button("Model Providers", systemImage: "cpu") { openProviders() }
                    .labelStyle(.iconOnly).buttonStyle(FritzButtonStyle(.toolbar)).help("Model Providers")
            }
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) {
                    newThreadToolbarButton
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) {
                    newThreadToolbarButton
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
                Button("Toggle Bottom Panel", systemImage: "rectangle.bottomthird.inset.filled") {
                    isBottomPanelPresented.toggle()
                }
                .labelStyle(.iconOnly).buttonStyle(FritzButtonStyle(.toolbar))
                .foregroundStyle(isBottomPanelPresented ? Color.accentColor : .secondary)
                .help(isBottomPanelPresented ? "Hide Bottom Panel" : "Show Bottom Panel")
                .accessibilityValue(isBottomPanelPresented ? "Shown" : "Hidden")
            }
        }
        .fritzWindowBackground()
        .frame(minWidth: 900, minHeight: 620)
        .sheet(isPresented: $state.isCreatingProject) { NewProjectSheet(workspace: state.workspace) }
        .sheet(item: $state.editor) { ProviderEditor(store: state.providers, existing: $0.connection) }
    }

    private var newThreadToolbarButton: some View {
        Button("New Thread", systemImage: "square.and.pencil", action: state.newThread)
            .buttonStyle(FritzButtonStyle(.toolbar)).help("New Thread (⌘N)")
            .disabled(state.workspace.projects.isEmpty || !state.workspace.canSave)
    }

    private func openProviders() {
        state.selectSettings(.providers)
        openSettings()
    }
}

private struct WorkspacePlaceholderPanel: View {
    let title: String
    let systemImage: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Spacer()
                Button("Close \(title)", systemImage: "xmark", action: close)
                    .modifier(FritzPanelIconControl())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FritzWindowStyle.contentBackground)
    }
}
