import FritzUpdates
import Fritz
import FritzUI
import SwiftUI

enum FritzSettingsTab: String, CaseIterable, Identifiable {
    case general
    case harness
    case service
    case archivedChats

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .harness: "Harness"
        case .service: "Service"
        case .archivedChats: "Archived Chats"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .harness: "slider.horizontal.3"
        case .service: "gearshape.2"
        case .archivedChats: "archivebox"
        }
    }
}

struct FritzSettingsView: View {
    @Bindable var state: FritzState
    @ObservedObject var updater: AppUpdater

    var body: some View {
        GeometryReader { geometry in
            NavigationSplitView(columnVisibility: .constant(.all)) {
                List(selection: selection) {
                    ForEach(FritzSettingsTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.systemImage).tag(tab)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(FritzWindowStyle.workspaceBackground)
                .frame(minWidth: 190, idealWidth: 205, maxWidth: 280)
                .navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 280)
                .toolbar(removing: .sidebarToggle)
            } detail: {
                Group {
                    switch state.settingsTab {
                    case .general:
                        FritzGeneralSettingsView(updater: updater, settings: state.settings, modelStorage: state.providers.modelStorage)
                    case .harness:
                        FritzHarnessSettingsView(settings: state.settings)
                    case .service:
                        FritzServiceSettingsView(agent: state.agent, localModels: state.localModels)
                    case .archivedChats:
                        FritzArchivedChatsView(workspace: state.workspace)
                    }
                }
                // Bound list-based pages to the window while reserving the bottom inset.
                .frame(height: max(0, geometry.size.height - 8), alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: FritzWindowStyle.cornerRadius, style: .continuous))
                .padding(.leading, 4).padding(.trailing, 8).padding(.bottom, 8)
            }
            .navigationSplitViewStyle(.prominentDetail)
            // Keep a toolbar host so the unified titlebar retains the sidebar outline.
            .toolbar {
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .automatic) {
                        Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .automatic) {
                        Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onChange(of: state.providers.modelStorage.settingsRequestID, initial: true) { _, request in
            if request != nil { state.selectSettings(.general) }
        }
        .fritzWindowBackground()
        .frame(minWidth: 800, minHeight: 500)

    }

    private var selection: Binding<FritzSettingsTab?> {
        Binding(
            get: { state.settingsTab },
            set: { if let tab = $0 { state.selectSettings(tab) } }
        )
    }
}

private struct FritzHarnessSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                tokenPicker("Context Budget", selection: $settings.harness.contextTokens,
                            options: [4_096, 8_192, 16_384, 32_768, 65_536, 131_072, 262_144, 524_288, 1_048_576])
                tokenPicker("Reply Reserve", selection: $settings.harness.reserveTokens,
                            options: [512, 1_024, 2_048, 4_096, 8_192, 16_384, 32_768])
            } header: {
                settingsTitle("Harness")
            } footer: {
                Text("For local chat, Automatic sizes the window to fit available Metal memory, up to the model’s limit. A fixed budget requests a specific window. For remote chat, Automatic uses the reported limit or the catalog. The reply reserve leaves room for generated text.")
            }
            Section {
                Toggle("Quantize Local KV Cache", isOn: Binding(
                    get: { settings.harness.quantizeLocalKVCache ?? false },
                    set: { settings.harness.quantizeLocalKVCache = $0 }
                ))
            } footer: {
                Text("An 8-bit attention cache uses less Metal memory and can fit a longer local context. Quantization can affect the model’s output.")
            }
            Section {
                Toggle("Automatically Compact History", isOn: $settings.harness.automaticCompaction)
                tokenPicker("Recent History to Keep", selection: $settings.harness.keepRecentTokens,
                            options: [512, 1_024, 2_048, 4_096, 8_192, 12_000, 20_000, 32_000, 64_000])
                    .disabled(!settings.harness.automaticCompaction)
            } footer: {
                Text("Compaction uses the selected model to summarize older messages. Remote models can incur an additional request charge. Your full transcript stays in Fritz.")
            }
        }
        .fritzSettingsFormStyle(background: .clear)
        .safeAreaInset(edge: .bottom) {
            if let error = settings.error {
                Text(error).foregroundStyle(.orange).textSelection(.enabled).padding()
            }
        }
    }

    private func tokenPicker(_ title: String, selection: Binding<Int>, options: [Int]) -> some View {
        Picker(title, selection: selection) {
            Text("Automatic").tag(0)
            ForEach(options, id: \.self) { value in
                Text(value, format: .number).tag(value)
            }
        }
    }
}

private struct FritzGeneralSettingsView: View {
    @ObservedObject var updater: AppUpdater
    @Bindable var settings: AppSettings
    let modelStorage: ModelStorage
    @State private var installResult: CommandLineInstaller.InstallResult?

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    LabeledContent("Appearance") {
                        Picker("Appearance", selection: $settings.appearance) {
                            ForEach(AppAppearance.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    LabeledContent("Update Channel") {
                        Picker("Update Channel", selection: $settings.updateChannel) {
                            ForEach(AppUpdateChannel.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    LabeledContent("Fritz Command Line") {
                        Button("Install Command Line") {
                            installResult = CommandLineInstaller().install()
                        }
                    }
                } header: {
                    settingsTitle("General")
                } footer: {
                    if let installResult {
                        Label(installResult.message, systemImage: installResult.systemImage)
                            .textSelection(.enabled)
                    }
                }
                Section {
                    ModelStorageLocation(storage: modelStorage)
                        .id("model-storage")
                }
                Section {
                    DisclosureGroup("Licenses") {
                        DisclosureGroup("Local Model Licenses") {
                            ForEach(NativeModelDescriptor.catalog + NativeModelDescriptor.decisionCatalog) { model in
                                Link(model.name, destination: model.licenseURL)
                            }
                        }
                        Link("Ollama Model Library", destination: URL(string: "https://ollama.com/library")!)
                    }
                }
            }
            .fritzSettingsFormStyle(background: .clear)
            .safeAreaInset(edge: .bottom) {
                if let error = settings.error { Text(error).foregroundStyle(.orange).textSelection(.enabled).padding() }
            }
            .onChange(of: settings.appearance) { _, value in
                (AppAppearance(rawValue: value) ?? .system).apply(to: NSApplication.shared)
            }
            .onChange(of: settings.updateChannel) { _, value in
                updater.setUpdateChannel(AppUpdateChannel(rawValue: value) ?? .release)
            }
            .task(id: modelStorage.settingsRequestID) {
                if let request = modelStorage.settingsRequestID {
                    await Task.yield()
                    guard !Task.isCancelled, modelStorage.settingsRequestID == request else { return }
                    proxy.scrollTo("model-storage", anchor: .center)
                    modelStorage.settingsRequestID = nil
                }
            }
        }
    }
}

private struct FritzServiceSettingsView: View {
    let agent: AgentClient
    let localModels: LocalModelRuntimeStore

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Label(agent.isRunning ? "Connected" : "Stopped",
                          systemImage: agent.isRunning ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(agent.isRunning ? .green : .secondary)
                }
                LabeledContent("Connection", value: "Private stdin/stdout pipes")
                LabeledContent("Owner", value: "Fritz.app")
            } header: {
                settingsTitle("Service")
            } footer: {
                if let error = agent.startupError {
                    Text(error).foregroundStyle(.orange).textSelection(.enabled)
                } else {
                    Text("Fritz supervises its bundled agent. Each active chat uses a separate fritz-harness process.")
                }
            }
            Section {
                let remote = localModels.remoteService
                LabeledContent("Status", value: remote.status.title)
                if let address = remote.address {
                    LabeledContent("Tunnel Target") { Text(address).textSelection(.enabled) }
                }
                if remote.status == .running {
                    Button("Copy Access Key") { localModels.copyRemoteModelKey() }
                    Button("Stop Sharing") { localModels.disableRemoteModels() }
                } else {
                    Button("Share Local Models") { localModels.enableRemoteModels() }
                        .disabled(remote.status == .starting || remote.status == .stopping)
                }
            } header: {
                Text("Remote Model Access")
            } footer: {
                if let error = localModels.remoteService.error {
                    Text(error).foregroundStyle(.orange).textSelection(.enabled)
                }
                Text("Use a private HTTPS tunnel to connect Fritz on iPhone. Stopping sharing or quitting Fritz revokes the access key.")
            }
            Section {
                LabeledContent("Status", value: localModels.service.status.title)
                if let pid = localModels.service.processID { LabeledContent("Process ID", value: String(pid)) }
                if let address = localModels.service.address {
                    LabeledContent("Address") { Text(address).textSelection(.enabled) }
                }
            } header: {
                Text("Local API")
            } footer: {
                if let error = localModels.service.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            }
        }
        .fritzSettingsFormStyle(background: .clear)
    }
}

private struct FritzArchivedChatsView: View {
    let workspace: WorkspaceStore
    @Environment(\.openWindow) private var openWindow
    @State private var chats: [ArchivedChat] = []
    @State private var hasMore = false
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var renaming: RenameItem?
    @State private var deleting: ArchivedChat?

    var body: some View {
        Group {
            if chats.isEmpty {
                if isLoading { ProgressView() }
                else if loadError == nil { ContentUnavailableView("No Archived Chats", systemImage: "archivebox") }
            } else {
                Form {
                    Section {
                        ForEach(chats) { chat in
                            HStack {
                                Button {
                                    Task {
                                        await workspace.select(chat.id)
                                        if workspace.selectedThreadID == chat.id { openWindow(id: "main") }
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(chat.title).lineLimit(1)
                                        Text(chat.projectName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                Button("Restore") { Task { await workspace.setArchived(chat.id, false) } }
                            }
                            .contextMenu {
                                Button("Rename Thread", systemImage: "pencil") {
                                    renaming = RenameItem(id: chat.id, title: chat.title, isProject: false)
                                }
                                Divider()
                                Button("Delete Thread…", systemImage: "trash", role: .destructive) { deleting = chat }
                            }
                            .disabled(!workspace.canSave || workspace.isEditing)
                        }
                    } header: {
                        settingsTitle("Archived Chats")
                    } footer: {
                        if hasMore {
                            Button("Load More") { Task { await load(before: chats.last) } }
                                .disabled(isLoading)
                        }
                    }
                }
                .fritzSettingsFormStyle(background: .clear)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            if let error = loadError ?? workspace.error {
                Text(error).foregroundStyle(.orange).textSelection(.enabled).padding()
            }
        }
        .task(id: workspace.archiveRevision) { await load() }
        .sheet(item: $renaming) { item in
            RenameItemSheet(item: item) { name in Task { await workspace.renameThread(item.id, to: name) } }
        }
        .alert("Delete Thread?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { chat in
            Button("Delete Thread", role: .destructive) { Task { await workspace.deleteThread(chat.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { chat in
            Text("“\(chat.title)” and its messages will be permanently deleted.")
        }
    }

    private func load(before cursor: ArchivedChat? = nil) async {
        if cursor != nil, isLoading { return }
        let revision = workspace.archiveRevision
        isLoading = true
        loadError = nil
        defer { if revision == workspace.archiveRevision { isLoading = false } }
        do {
            let page = try await workspace.repository.archivedChats(before: cursor)
            guard revision == workspace.archiveRevision, !Task.isCancelled else { return }
            chats = cursor == nil ? page.rows : chats + page.rows
            hasMore = page.hasMore
        } catch {
            guard revision == workspace.archiveRevision, !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
    }
}

private func settingsTitle(_ title: String) -> some View {
    Text(title)
        .font(.headline)
        .foregroundStyle(.primary)
        .accessibilityAddTraits(.isHeader)
        .listRowBackground(Color.clear)
}

private extension CommandLineInstaller.InstallResult {
    var message: String {
        switch self {
        case let .installed(url): "Installed fritz at \(url.path)."
        case let .alreadyInstalled(url): "fritz is already installed at \(url.path)."
        case .appNotInstalled: "Install Fritz in /Applications, then try again."
        case .noAvailableDirectory: "No writable folder in PATH is available."
        case let .failed(message): "Could not install fritz: \(message)"
        }
    }

    var systemImage: String {
        switch self {
        case .installed, .alreadyInstalled: "checkmark.circle.fill"
        case .appNotInstalled, .noAvailableDirectory, .failed: "exclamationmark.triangle.fill"
        }
    }
}
