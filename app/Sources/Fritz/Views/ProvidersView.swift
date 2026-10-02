import AppKit
import Fritz
import FritzUI
import SwiftUI

struct ProviderEditorSelection: Identifiable {
    let id = UUID()
    var connection: ProviderConnection? = nil
}

struct ProvidersView: View {
    @Bindable var store: ProviderStore
    @Bindable var localModels: LocalModelRuntimeStore
    @Binding var editor: ProviderEditorSelection?
    @State private var selectedIDs: Set<UUID> = []
    @State private var deleting: ProviderConnection?
    @State private var isImporting = false
    @State private var showsExportOptions = false
    @State private var exportConnections: [ProviderConnection] = []
    @State private var textExport: ProviderTextExport?

    var body: some View {
        ModelsView(
            providers: providerItems, selectedProviderIDs: $selectedIDs,
            sessions: [LocalModelSessionItem<String>](),
            isLoadingProviders: store.isLoading, providerError: store.error,
            background: FritzWindowStyle.workspaceBackground,
            actionControlSize: .extraLarge,
            transferActions: { transferMenu.controlSize(.extraLarge) },
            addProvider: { editor = ProviderEditorSelection() },
            editProvider: { id in
                if let connection = store.connections.first(where: { $0.id == id }) {
                    editor = ProviderEditorSelection(connection: connection)
                }
            },
            canMakeDefault: { id in
                store.connections.contains { $0.id == id && $0.category == .llm }
                    && id != store.registry.defaultConnectionId
            },
            showsMakeDefault: { id in
                store.connections.contains { $0.id == id && $0.category == .llm }
            },
            makeDefault: { id in
                if let connection = store.connections.first(where: { $0.id == id }) {
                    Task { await store.makeDefault(connection) }
                }
            },
            exportProviders: prepareExport,
            deleteProvider: { id in
                deleting = store.connections.first(where: { $0.id == id })
            }
        )
        .sheet(isPresented: $isImporting) { ProviderTransferSheet(store: store) }
        .confirmationDialog("Export", isPresented: $showsExportOptions) {
            Button("Export Without Keys") { exportProviders(includeKeys: false) }
            Button("Export Including API Keys") { exportProviders(includeKeys: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Included API keys will be readable in the export.")
        }
        .sheet(item: $textExport) { exported in ProviderTransferSheet(store: store, exported: exported) }
        .onChange(of: store.connections) { _, connections in selectedIDs.formIntersection(connections.map(\.id)) }
        .confirmationDialog("Delete this provider?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            if let deleting {
                Button("Delete \(deleting.providerDisplayName)", role: .destructive) { Task {
                    await store.remove(deleting)
                    if deleting.provider == .fritz, !store.connections.contains(where: { $0.id == deleting.id }) {
                        localModels.stop(deleting.modelID)
                    }
                }; self.deleting = nil }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("This removes the connection and its saved key from Fritz.") }
        .buttonStyle(FritzButtonStyle())
    }

    @ViewBuilder private var transferMenu: some View {
        if #available(macOS 26.0, *) {
            transferMenuContent.buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            transferMenuContent
        }
    }

    private var transferMenuContent: some View {
        Menu {
            Button("Import…", systemImage: "square.and.arrow.down") { isImporting = true }
            Button("Export…", systemImage: "square.and.arrow.up") { prepareExport(selectedIDs) }
                .disabled(selectedIDs.isEmpty)
        } label: {
            Label("Import and Export", systemImage: "ellipsis")
        }
        .labelStyle(.iconOnly).menuIndicator(.hidden)
        .help("Import and Export")
    }

    private var providerItems: [ModelProviderItem<UUID>] {
        store.connections.map { connection in
            let names = store.catalog[connection.id].map { models in
                models.isEmpty ? "No models" : DiscoveredAIModel.preferredOrder(models, provider: connection.provider)
                    .map(\.displayName).joined(separator: ", ")
            } ?? (store.isLoading || connection.modelID.isEmpty ? nil : connection.modelID)
            return ModelProviderItem(
                id: connection.id, name: connection.providerDisplayName,
                warning: store.discoveryErrors[connection.id],
                isLocal: connection.provider.isNative || connection.provider == .ollama,
                isDefault: connection.id == store.registry.defaultConnectionId,
                models: names, nameHelp: connection.name
            )
        }
    }
    private func prepareExport(_ ids: Set<UUID>) {
        exportConnections = store.connections.filter { ids.contains($0.id) }
        if !exportConnections.isEmpty { showsExportOptions = true }
    }

    private func exportProviders(includeKeys: Bool) {
        do {
            let text = try store.exportProviders(exportConnections, includeKeys: includeKeys)
            textExport = ProviderTextExport(text: text, includesKeys: includeKeys)
        } catch { store.error = error.localizedDescription }
    }
}

struct ProviderEditor: View {
    let store: ProviderStore
    @Bindable var localModels: LocalModelRuntimeStore
    let existing: ProviderConnection?
    @Environment(\.dismiss) private var dismiss
    @State private var id: UUID
    @State private var name: String
    @State private var preset: AIProviderPreset
    @State private var endpoint: String
    @State private var apiKey = ""
    @State private var isAPIKeyVisible = false
    @State private var modelID: String
    @State private var makeDefault: Bool
    @State private var models: [DiscoveredAIModel] = []
    @State private var isDiscovering = false
    @State private var isSaving = false
    @State private var error: String?
    @State private var discoveryError: String?
    @State private var discoveryFinished = false
    @State private var showsAdvanced = false
    @State private var showsModels = false
    @State private var refreshID = 0
    @State private var activeDiscoveryID = UUID()
    @State private var nativeModel: NativeLocalModel
    @State private var startPolicy: LocalModelRuntimeStore.StartPolicy
    @State private var showsDownload = false
    @State private var saveTask: Task<Void, Never>?

    init(store: ProviderStore, localModels: LocalModelRuntimeStore, existing: ProviderConnection?) {
        self.store = store; self.localModels = localModels; self.existing = existing
        let addedPresets = Set(store.connections.map {
            AIProviderPreset.matching(provider: $0.provider, baseURL: $0.baseURL)
        })
        let initialPreset = existing.map { AIProviderPreset.matching(provider: $0.provider, baseURL: $0.baseURL) }
            ?? AIProviderPreset.allCases.first { $0.category == .llm && !addedPresets.contains($0) }
            ?? .adapter(.openAI)
        let category = initialPreset.category
        _id = State(initialValue: existing?.id ?? UUID())
        let initialNativeModel = NativeLocalModel(agent: store.agent, modelID: existing?.modelID, category: category)
        _nativeModel = State(initialValue: initialNativeModel)
        _startPolicy = State(initialValue: localModels.policy(for: initialNativeModel.selectedModelID))
        let baseName = initialPreset.name
        var initialName = baseName, suffix = 2
        while store.connections.contains(where: { $0.name.caseInsensitiveCompare(initialName) == .orderedSame }) {
            initialName = "\(baseName) \(suffix)"; suffix += 1
        }
        _name = State(initialValue: existing?.name ?? initialName)
        _preset = State(initialValue: initialPreset)
        _endpoint = State(initialValue: existing?.baseURL ?? initialPreset.baseURL)
        _modelID = State(initialValue: existing?.modelID ?? (category == .decision ? "jev-latest" : ""))
        _makeDefault = State(initialValue: category == .llm &&
                             (existing?.id == store.registry.defaultConnectionId || store.registry.defaultConnectionId == nil))
    }

    var body: some View {
        ModelProviderEditor(
            primaryActionTitle: primaryActionTitle, canSave: canSave, isSaving: isSaving,
            height: editorHeight,
            contentBackground: FritzWindowStyle.contentBackground,
            footerBackground: FritzWindowStyle.workspaceBackground,
            cancel: { nativeModel.cancel(); dismiss() }, save: save
        ) {
            FritzManagementHeader(existing == nil ? "New Models" : "Edit Models")
        } content: {
            Form {
                Section {
                    if existing == nil {
                        AIProviderPicker(selection: $preset)
                    } else {
                        Picker("Provider", selection: $preset) {
                            ForEach(AIProviderPreset.allCases) { provider in
                                Text(provider.name).tag(provider)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }.disabled(nativeModel.state.isBusy)
                if managesLocalModels {
                    Section {
                        Picker("Model", selection: Binding(
                            get: { nativeModel.selectedModelID },
                            set: { nativeModel.select($0) }
                        )) {
                            ForEach(nativeModel.catalog) { model in
                                Text(model.name).tag(model.id)
                            }
                        }
                        if managesLocalAPI {
                            Picker("Start on", selection: $startPolicy) {
                                ForEach(LocalModelRuntimeStore.StartPolicy.allCases) { policy in
                                    Text(policy.title).tag(policy)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    } footer: {
                        switch nativeModel.state {
                        case .installed: EmptyView()
                        case .checking: Text("Checking…")
                        case .failed(let message): Text(message).foregroundStyle(.red)
                        case .available, .downloading: Text("Not installed")
                        }
                        if let duplicateConnection {
                            duplicateWarning(duplicateConnection)
                        }
                        if nativeModel.state == .installed, let url = nativeModel.installedURL {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Installed at")
                                HStack(spacing: 6) {
                                    Text(url.path).textSelection(.enabled)
                                        .lineLimit(1).truncationMode(.middle)
                                    Button("Copy Path", systemImage: "doc.on.doc") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(url.path, forType: .string)
                                    }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(FritzButtonStyle(.inline))
                                    .help("Copy Path")
                                    .fixedSize()
                                }
                            }
                            .padding(.top, 6)
                        }
                        HStack(spacing: 8) {
                            Button("Download") { showsDownload = true }
                            if managesLocalAPI {
                                if localSession.status == .running || localSession.status == .starting || localSession.status == .stopping {
                                    Button("Stop") { localModels.stop(nativeModel.selectedModelID) }
                                        .disabled(localSession.status == .stopping)
                                } else {
                                    Button("Start") { localModels.start(nativeModel.selectedModelID) }
                                        .disabled(nativeModel.state != .installed || localModels.isLoading
                                                  || !localModels.installedIDs.contains(nativeModel.selectedModelID))
                                }
                            }
                            if nativeModel.state == .installed, let url = nativeModel.installedURL {
                                Button("Open in Finder", systemImage: "folder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            }
                        }
                        .padding(.top, 6)
                        if managesLocalAPI { localRuntimeControls.padding(.top, 12) }
                        if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    }
                    if category == .llm && store.registry.defaultConnectionId != nil {
                        Section {
                            Toggle("Use as Default Provider", isOn: $makeDefault)
                                .disabled(existing?.id == store.registry.defaultConnectionId)
                        }
                    }
                } else {
                    remoteSections
                }
            }
            .fritzSettingsFormStyle().disabled(isSaving)
        }
        .buttonStyle(FritzButtonStyle())
        .interactiveDismissDisabled(isSaving)
        .onChange(of: preset) { old, new in
            nativeModel.cancel()
            if old.category != new.category {
                makeDefault = new.category == .llm &&
                    (existing?.id == store.registry.defaultConnectionId || store.registry.defaultConnectionId == nil)
            }
            if existing == nil || name == old.name { name = suggestedName(new.name) }
            endpoint = new.baseURL; apiKey = ""; isAPIKeyVisible = false
            modelID = new.category == .decision ? "jev-latest" : ""
            models = []; error = nil; discoveryError = nil; discoveryFinished = false; refreshID = 0
            showsModels = false
        }
        .onChange(of: nativeModel.selectedModelID) { _, modelID in
            startPolicy = localModels.policy(for: modelID)
        }
        .task(id: preset.provider) {
            nativeModel.cancel()
            if nativeModel.category != category {
                nativeModel = NativeLocalModel(agent: store.agent, category: category)
            }
            if managesLocalModels { nativeModel.refresh() }
            if preset.provider == .fritz { await localModels.refresh() }
        }
        .sheet(isPresented: $showsDownload, onDismiss: {
            nativeModel.refresh()
            Task { await localModels.refresh() }
        }) {
            LocalModelDownloadSheet(agent: store.agent, modelID: nativeModel.selectedModelID, category: category)
        }
        .onDisappear { nativeModel.cancel(); saveTask?.cancel() }
        .task(id: discoveryKey) { await discover() }
    }

    private var localSession: LocalModelRuntimeStore.Session {
        localModels.sessions[nativeModel.selectedModelID] ?? .init()
    }

    private var managesLocalAPI: Bool {
        preset.provider == .fritz
    }

    private var localRuntimeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if localSession.status == .starting { ProgressView().controlSize(.small) }
                Text(localSession.status.title)
                    .foregroundStyle(localSession.status == .running ? .green : .secondary)
                if let processID = localSession.processID {
                    Text("· PID \(String(processID))").monospacedDigit()
                }
            }
            if let address = localModels.service.address { Text(address).textSelection(.enabled) }
            if let error = localModels.policyError ?? localSession.error ?? localModels.service.error ?? localModels.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var remoteSections: some View {
        Section {
            if requiresEndpoint { endpointField }
            LabeledContent(apiKeyTitle) {
                HStack(spacing: 8) {
                    Group {
                        if isAPIKeyVisible {
                            TextField(apiKeyTitle, text: $apiKey, prompt: Text(keyPrompt))
                        } else {
                            SecureField(apiKeyTitle, text: $apiKey, prompt: Text(keyPrompt))
                        }
                    }.labelsHidden().privacySensitive().accessibilityLabel(apiKeyTitle)
                    Button(isAPIKeyVisible ? "Hide API Key" : "Show API Key", systemImage: isAPIKeyVisible ? "eye.slash" : "eye") {
                        isAPIKeyVisible.toggle()
                    }
                    .labelStyle(.iconOnly).frame(width: 24, height: 20).disabled(apiKey.isEmpty)
                    .help(isAPIKeyVisible ? "Hide API Key" : "Show API Key")
                }
            }
            if category == .decision {
                LabeledContent("Model", value: "Jev · jev-latest")
                TextField("Connection name", text: $name)
            } else {
                LabeledContent("Models") {
                    HStack(spacing: 8) {
                        Text(isDiscovering ? "Loading…" : "\(models.count) available").foregroundStyle(.secondary)
                        Button("Show Models") { showsModels = true }
                            .disabled(models.isEmpty)
                            .popover(isPresented: $showsModels) {
                                ProviderModelsPopover(models: models, recentModelIDs: store.recentIDs, connectionID: id)
                            }
                        Button("Refresh Models", systemImage: "arrow.clockwise") { refreshID += 1 }
                            .labelStyle(.iconOnly).frame(width: 24, height: 20).help("Refresh Models")
                            .disabled(isDiscovering).opacity(isDiscovering ? 0 : 1)
                            .overlay { if isDiscovering { ProgressView().controlSize(.small) } }
                    }.frame(minHeight: 20)
                }
            }
            if category == .llm && store.registry.defaultConnectionId != nil {
                Toggle("Use as Default Provider", isOn: $makeDefault)
                    .disabled(existing?.id == store.registry.defaultConnectionId)
            }
        } footer: {
            if let duplicateConnection {
                duplicateWarning(duplicateConnection)
            }
            if category == .decision, let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            } else if let discoveryError {
                Label(discoveryError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if discoveryFinished, models.isEmpty {
                Text("No models found.").foregroundStyle(.secondary)
            }
        }
        Section {
            if showsAdvanced {
                if !requiresEndpoint { endpointField }
                if category == .llm {
                    TextField("Connection name", text: $name)
                    if !models.isEmpty {
                        Picker("Default model", selection: $modelID) {
                            Text("Choose automatically").tag("")
                            if !modelID.isEmpty && !models.contains(where: { $0.id == modelID }) { Text(modelID).tag(modelID) }
                            ForEach(models) { Text($0.displayName).tag($0.id) }
                        }
                    }
                    TextField("Model ID", text: $modelID, prompt: Text("Optional manual model ID")).autocorrectionDisabled()
                }
            }
        } header: {
            Button {
                showsAdvanced.toggle()
            } label: {
                Label("Advanced", systemImage: showsAdvanced ? "chevron.down" : "chevron.right")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(FritzButtonStyle(.inline))
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(showsAdvanced ? "Expanded" : "Collapsed")
            .help(showsAdvanced ? "Hide advanced settings" : "Show advanced settings")
        } footer: {
            if category == .llm, let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
    }

    private func duplicateWarning(_ connection: ProviderConnection) -> some View {
        Label("Already added as \(connection.name).", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
    }

    private var endpointField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(endpointTitle)
            TextField(endpointTitle, text: $endpoint, prompt: Text(endpointPrompt))
                .labelsHidden().autocorrectionDisabled()
                .accessibilityLabel(endpointTitle)
        }
    }

    private var category: AIModelCategory { preset.category }
    private var managesLocalModels: Bool { preset.provider.isNative }
    private var requiresEndpoint: Bool { preset == .adapter(.openAICompatible) }
    private var resolvedEndpoint: String {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? preset.baseURL : value
    }
    private var editorHeight: CGFloat {
        let base: CGFloat
        if managesLocalModels {
            base = 340 + (category == .llm && store.registry.defaultConnectionId != nil ? 40 : 0)
                + (managesLocalAPI ? 65 : 0)
                + (nativeModel.installedURL == nil ? 0 : 50)
        } else if category == .decision {
            base = 350 + (showsAdvanced ? 100 : 0)
        } else {
            base = 370 + (requiresEndpoint ? 64 : 0) + (showsAdvanced ? (requiresEndpoint ? 150 : 250) : 0)
                + (store.connections.isEmpty ? 0 : 32)
                + (discoveryError == nil ? 0 : 60)
        }
        return base - (existing == nil ? 32 : 0) + (duplicateConnection == nil ? 0 : 44)
    }
    private var primaryActionTitle: String { existing == nil ? "Add" : "Save" }
    private var apiKeyTitle: String { preset.requiresAPIKey ? "API Key" : "API Key (Optional)" }
    private var endpointTitle: String { requiresEndpoint ? "Gateway URL" : "Gateway URL (Optional)" }
    private var endpointPrompt: String {
        if requiresEndpoint { return "https://api.example.com/v1" }
        return preset.baseURL.isEmpty ? preset.provider.endpoint : preset.baseURL
    }
    private var keepsSavedKey: Bool {
        guard let existing, existing.provider == preset.provider else { return false }
        let old = existing.baseURL?.isEmpty == false ? existing.baseURL! : existing.provider.endpoint
        let current = resolvedEndpoint.isEmpty ? preset.provider.endpoint : resolvedEndpoint
        return old.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == current.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private var keyPrompt: String { keepsSavedKey ? "**********" : "Enter API key" }
    private var canSave: Bool {
        !isSaving && duplicateConnection == nil
            && (!managesLocalAPI || localModels.policyError == nil)
            && (!managesLocalModels || nativeModel.category == category && nativeModel.state == .installed)
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!preset.requiresAPIKey || !apiKey.isEmpty || keepsSavedKey)
            && (!requiresEndpoint || !resolvedEndpoint.isEmpty)
    }
    private var discoveryKey: DiscoveryKey { DiscoveryKey(provider: preset, endpoint: endpoint, apiKey: apiKey, refresh: refreshID) }
    private var connection: ProviderConnection {
        ProviderConnection(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), provider: preset.provider,
                           baseURL: managesLocalModels || resolvedEndpoint.isEmpty ? nil : resolvedEndpoint,
                           modelID: managesLocalModels ? nativeModel.selectedModelID : category == .decision ? "jev-latest" : modelID.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private var duplicateConnection: ProviderConnection? {
        let candidate = connection
        return store.connections.first { saved in
            guard saved.id != candidate.id, saved.provider == candidate.provider else { return false }
            if candidate.provider.isNative { return saved.modelID == candidate.modelID }
            let savedEndpoint = saved.baseURL?.isEmpty == false ? saved.baseURL! : saved.provider.endpoint
            let candidateEndpoint = candidate.baseURL?.isEmpty == false ? candidate.baseURL! : candidate.provider.endpoint
            return savedEndpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                == candidateEndpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
    }
    private func suggestedName(_ base: String) -> String {
        var candidate = base, count = 2
        while store.connections.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) {
            candidate = "\(base) \(count)"; count += 1
        }
        return candidate
    }
    private func discover() async {
        guard !managesLocalModels && category == .llm else { return }
        let token = UUID()
        activeDiscoveryID = token
        showsModels = false
        isDiscovering = false; discoveryError = nil; discoveryFinished = false; models = []
        guard !preset.requiresAPIKey || !apiKey.isEmpty || keepsSavedKey else {
            if refreshID > 0 { discoveryError = "Enter an API key, then refresh." }; return
        }
        guard !requiresEndpoint || !resolvedEndpoint.isEmpty else {
            if refreshID > 0 { discoveryError = "Enter an endpoint to load models." }; return
        }
        isDiscovering = true
        defer { if activeDiscoveryID == token { isDiscovering = false } }
        do {
            try await Task.sleep(for: .milliseconds(250))
            var params: [String: Any] = ["connection": try connection.jsonObject()]
            if !apiKey.isEmpty { params["apiKey"] = apiKey }
            let response: ModelCatalog = try await store.agent.request("models.list", params: params)
            try Task.checkCancellation()
            guard activeDiscoveryID == token else { return }
            models = DiscoveredAIModel.preferredOrder(response.models, provider: preset.provider)
            discoveryFinished = true
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, activeDiscoveryID == token else { return }
            discoveryError = error.localizedDescription; discoveryFinished = true
        }
    }
    private func save() {
        guard canSave else { return }
        isSaving = true; error = nil
        saveTask = Task {
            defer { isSaving = false; saveTask = nil }
            do {
                let saved = connection
                try await store.save(saved, key: apiKey, makeDefault: makeDefault)
                if let existing, existing.provider == .fritz,
                   saved.provider != .fritz || saved.modelID != existing.modelID {
                    localModels.stop(existing.modelID)
                }
                if saved.provider == .fritz {
                    try localModels.setPolicy(startPolicy, for: saved.modelID)
                }
                try Task.checkCancellation()
                apiKey = ""; dismiss()
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct ProviderModelsPopover: View {
    let models: [DiscoveredAIModel]
    let recentModelIDs: [String]
    let connectionID: UUID
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search models", text: $searchText)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.leading)
                    .focused($isSearchFocused)
            }
            .padding(12)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if !recentModels.isEmpty {
                        section("Recent", models: recentModels)
                    }
                    if !otherModels.isEmpty {
                        section(recentModels.isEmpty ? "Models" : "Other Models", models: otherModels)
                    }
                    if recentModels.isEmpty && otherModels.isEmpty {
                        Text("No matching models")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 420, height: 360)
        .background(FritzWindowStyle.contentBackground)
        .onAppear { isSearchFocused = true }
    }

    private var filteredModels: [DiscoveredAIModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return models }
        return models.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    private var recentModels: [DiscoveredAIModel] {
        let prefix = "connection:\(connectionID.uuidString):"
        return recentModelIDs.compactMap { recentID in
            guard recentID.hasPrefix(prefix) else { return nil }
            let modelID = String(recentID.dropFirst(prefix.count))
            return filteredModels.first { $0.id == modelID }
        }
    }

    private var otherModels: [DiscoveredAIModel] {
        let recentIDs = Set(recentModels.map(\.id))
        return filteredModels.filter { !recentIDs.contains($0.id) }
    }

    private func section(_ title: String, models: [DiscoveredAIModel]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(models) { model in
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                    if model.id != model.displayName {
                        Text(model.id).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .textSelection(.enabled)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct DiscoveryKey: Hashable {
    let provider: AIProviderPreset
    let endpoint: String
    let apiKey: String
    let refresh: Int
}
