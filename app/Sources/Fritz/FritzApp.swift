import SwiftUI

@MainActor @Observable final class FritzState {
    static let shared = FritzState()
    let agent: AgentClient
    let providers: ProviderStore
    let workspace: WorkspaceStore
    var isCreatingProject = false
    var editor: ProviderEditorSelection?

    init() {
        let agent = AgentClient()
        self.agent = agent
        providers = ProviderStore(agent: agent)
        workspace = WorkspaceStore(agent: agent)
    }
    func newThread() {
        if let project = workspace.selectedProject ?? workspace.projects.first {
            workspace.createThread(in: project.id)
        } else { isCreatingProject = true }
    }
}

@MainActor final class FritzAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        FritzState.shared.workspace.shutdown()
        FritzState.shared.agent.stop()
    }
}

@main struct FritzApp: App {
    @NSApplicationDelegateAdaptor(FritzAppDelegate.self) private var delegate
    @State private var state = FritzState.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Fritz", id: "main") {
            FritzWorkspaceView(state: state)
                .task {
                    state.agent.start()
                    await state.providers.refresh()
                }
        }
        .defaultSize(width: 1080, height: 760)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { state.isCreatingProject = true; openWindow(id: "main") }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Thread") { state.newThread(); openWindow(id: "main") }.keyboardShortcut("n")
            }
            CommandGroup(replacing: .appSettings) {
                Button("Model Providers…") { openWindow(id: "providers") }.keyboardShortcut(",")
            }
            CommandMenu("Chat") {
                Button("Show Chat") { openWindow(id: "main") }.keyboardShortcut("1")
                Button("Stop Response") { state.workspace.selectedChat?.stop() }.keyboardShortcut(".")
                    .disabled(state.workspace.selectedChat?.isResponding != true)
            }
        }

        Window("Model Providers", id: "providers") {
            ProvidersWindowContent(store: state.providers)
        }
        .defaultSize(width: 860, height: 540)
        .windowStyle(.hiddenTitleBar)
    }
}

private struct FritzWorkspaceView: View {
    @Bindable var state: FritzState
    @Environment(\.openWindow) private var openWindow
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var isRightPanelPresented = false
    @State private var isBottomPanelPresented = false

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            ProjectsSidebar(workspace: state.workspace, newProject: { state.isCreatingProject = true })
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
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
                                         openProviders: { openWindow(id: "providers") },
                                         addProvider: { state.editor = ProviderEditorSelection() })
                                    .id(thread.id)
                            }
                            .background(FritzWindowStyle.contentBackground)
                        } else {
                            ContentUnavailableView {
                                Label("Start a project", systemImage: "folder.badge.plus")
                            } description: {
                                Text("Keep your coding conversations together, one project at a time.")
                            } actions: {
                                Button("New Project") { state.isCreatingProject = true }
                                    .buttonStyle(FritzButtonStyle(.primary)).disabled(!state.workspace.canSave)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(FritzWindowStyle.contentBackground)
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
            .background(FritzWindowStyle.workspaceBackground)
        }
        .navigationSplitViewStyle(.prominentDetail)
        .background(FritzWindowStyle.workspaceBackground)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                WindowNewItemMenu(canCreateThread: !state.workspace.projects.isEmpty,
                                  createProject: { state.isCreatingProject = true },
                                  createThread: state.newThread,
                                  createProvider: { state.editor = ProviderEditorSelection() })
            }
            ToolbarItem(placement: .principal) {
                Button("Model Providers", systemImage: "cpu") { openWindow(id: "providers") }
                    .labelStyle(.iconOnly).buttonStyle(FritzButtonStyle(.toolbar)).help("Model Providers")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New Thread", systemImage: "square.and.pencil", action: state.newThread)
                    .buttonStyle(FritzButtonStyle(.toolbar)).help("New Thread (⌘N)")
                    .disabled(state.workspace.projects.isEmpty || !state.workspace.canSave)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Toggle Right Panel", systemImage: "sidebar.right") {
                    isRightPanelPresented.toggle()
                }
                .labelStyle(.iconOnly).buttonStyle(FritzButtonStyle(.toolbar))
                .foregroundStyle(isRightPanelPresented ? Color.accentColor : .secondary)
                .help(isRightPanelPresented ? "Hide Right Panel" : "Show Right Panel")
                .accessibilityValue(isRightPanelPresented ? "Shown" : "Hidden")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Toggle Bottom Panel", systemImage: "rectangle.bottomthird.inset.filled") {
                    isBottomPanelPresented.toggle()
                }
                .labelStyle(.iconOnly).buttonStyle(FritzButtonStyle(.toolbar))
                .foregroundStyle(isBottomPanelPresented ? Color.accentColor : .secondary)
                .help(isBottomPanelPresented ? "Hide Bottom Panel" : "Show Bottom Panel")
                .accessibilityValue(isBottomPanelPresented ? "Shown" : "Hidden")
            }
        }
        .toolbarBackground(FritzWindowStyle.workspaceBackground, for: .windowToolbar)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(minWidth: 900, minHeight: 620)
        .sheet(isPresented: $state.isCreatingProject) { NewProjectSheet(workspace: state.workspace) }
        .sheet(item: $state.editor) { ProviderEditor(store: state.providers, existing: $0.connection) }
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

            Divider()

            Text("This panel is a placeholder for future workspace tools.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(16)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FritzWindowStyle.contentBackground)
    }
}

private struct ProvidersWindowContent: View {
    let store: ProviderStore
    @State private var editor: ProviderEditorSelection?
    var body: some View {
        ProvidersView(store: store, editor: $editor)
            .frame(minWidth: 720, minHeight: 440)
            .sheet(item: $editor) { ProviderEditor(store: store, existing: $0.connection) }
    }
}
