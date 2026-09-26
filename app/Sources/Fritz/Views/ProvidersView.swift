import Fritz
import FritzUI
import SwiftUI

struct ProviderEditorSelection: Identifiable {
    let id = UUID()
    var connection: ProviderConnection? = nil
    var category: AIModelCategory = .llm
}

struct ProvidersView: View {
    @Bindable var store: ProviderStore
    @Binding var editor: ProviderEditorSelection?
    @State private var selectedIDs: Set<UUID> = []
    @State private var deleting: ProviderConnection?
    @State private var isImporting = false
    @State private var showsExportOptions = false
    @State private var exportConnections: [ProviderConnection] = []
    @State private var textExport: ProviderTextExport?

    var body: some View {
        VStack(spacing: 0) {
            FritzManagementHeader("Model Providers") {
                transferMenu
                Button("Add Provider", systemImage: "plus") {
                    editor = ProviderEditorSelection()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(FritzButtonStyle(.floating, shape: .circle))
                .help("Add Provider")
            }

            ModelProvidersTable(providers: providerItems, selection: $selectedIDs, isLoading: store.isLoading) { id in
                if let connection = store.connections.first(where: { $0.id == id }) {
                    editor = ProviderEditorSelection(connection: connection)
                }
            }
            .fritzListSurface()
            .contextMenu(forSelectionType: UUID.self) { ids in
                if ids.count == 1, let connection = store.connections.first(where: { ids.contains($0.id) }) {
                    Button("Edit Provider", systemImage: "pencil") { editor = ProviderEditorSelection(connection: connection) }
                    if connection.category == .llm {
                        Button("Make Default", systemImage: "checkmark.circle") { Task { await store.makeDefault(connection) } }
                            .disabled(connection.id == store.registry.defaultConnectionId)
                    }
                    Divider()
                    Button("Delete Provider", role: .destructive) { deleting = connection }
                }
                if !ids.isEmpty {
                    Button("Export Providers…", systemImage: "square.and.arrow.up") { prepareExport(ids) }
                }
            } primaryAction: { ids in
                if ids.count == 1, let connection = store.connections.first(where: { ids.contains($0.id) }) {
                    editor = ProviderEditorSelection(connection: connection)
                }
            }
            .onDeleteCommand { deleting = selectedConnection }
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled).padding(12)
            }
        }
        .background(FritzWindowStyle.workspaceBackground)
        .sheet(isPresented: $isImporting) { ProviderTransferSheet(store: store) }
        .confirmationDialog("Export Providers", isPresented: $showsExportOptions) {
            Button("Export Without Keys") { exportProviders(includeKeys: false) }
            Button("Export Including API Keys") { exportProviders(includeKeys: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Included API keys will be readable in the exported JSON.")
        }
        .sheet(item: $textExport) { exported in ProviderTransferSheet(store: store, exported: exported) }
        .onChange(of: store.connections) { _, connections in selectedIDs.formIntersection(connections.map(\.id)) }
        .confirmationDialog("Delete this provider?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            if let deleting {
                Button("Delete \(deleting.providerDisplayName)", role: .destructive) { Task { await store.remove(deleting) }; self.deleting = nil }
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
            Button("Import Providers…", systemImage: "square.and.arrow.down") { isImporting = true }
            Button("Export Providers…", systemImage: "square.and.arrow.up") { prepareExport(selectedIDs) }
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
                models.isEmpty ? "No models" : models.map(\.displayName).joined(separator: ", ")
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
    private var selectedConnection: ProviderConnection? {
        selectedIDs.count == 1 ? store.connections.first { selectedIDs.contains($0.id) } : nil
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
    let existing: ProviderConnection?
    @Environment(\.dismiss) private var dismiss
    @State private var id: UUID
    @State private var name: String
    @State private var preset: AIProviderPreset
    @State private var category: AIModelCategory
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
    @State private var refreshID = 0
    @State private var activeDiscoveryID = UUID()
    @State private var nativeModel: NativeLocalModel
    @State private var showsDownload = false
    @State private var saveTask: Task<Void, Never>?

    init(store: ProviderStore, existing: ProviderConnection?, initialCategory: AIModelCategory = .llm) {
        self.store = store; self.existing = existing
        let category = existing?.category ?? initialCategory
        _category = State(initialValue: category)
        _id = State(initialValue: existing?.id ?? UUID())
        _nativeModel = State(initialValue: NativeLocalModel(agent: store.agent, modelID: existing?.modelID, category: category))
        let baseName = category == .decision ? "TypeSafe" : "OpenAI"
        var initialName = baseName, suffix = 2
        while store.connections.contains(where: { $0.name.caseInsensitiveCompare(initialName) == .orderedSame }) {
            initialName = "\(baseName) \(suffix)"; suffix += 1
        }
        _name = State(initialValue: existing?.name ?? initialName)
        _preset = State(initialValue: existing.map { .matching(provider: $0.provider, baseURL: $0.baseURL) }
                        ?? (category == .decision ? .adapter(.jev) : .adapter(.openAI)))
        _endpoint = State(initialValue: existing?.baseURL ?? "")
        _modelID = State(initialValue: existing?.modelID ?? (category == .decision ? "jev-latest" : ""))
        _makeDefault = State(initialValue: category == .llm &&
                             (existing?.id == store.registry.defaultConnectionId || store.registry.defaultConnectionId == nil))
    }

    var body: some View {
        ModelProviderEditor(
            primaryActionTitle: primaryActionTitle, canSave: canSave, isSaving: isSaving,
            height: managesLocalModels ? 340 + (store.connections.isEmpty ? 0 : 40) : category == .decision ? 430 : 400 + (showsAdvanced ? 150 : 0) + (store.connections.isEmpty ? 0 : 32) + (discoveryError == nil ? 0 : 60),
            contentBackground: FritzWindowStyle.contentBackground,
            footerBackground: FritzWindowStyle.workspaceBackground,
            cancel: { nativeModel.cancel(); dismiss() }, save: save
        ) {
            FritzManagementHeader(existing == nil ? "New Provider" : "Edit Provider")
        } content: {
            Form {
                if existing == nil {
                    Section {
                        Picker("Model category", selection: $category) {
                            ForEach(AIModelCategory.allCases) { option in Text(option.title).tag(option) }
                        }
                    }
                }
                Section {
                    AIProviderPicker(selection: $preset,
                                     providers: AIProviderPreset.allCases.filter { $0.category == category })
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
                        Button("Download Model…") { showsDownload = true }
                    } footer: {
                        switch nativeModel.state {
                        case .installed: Text(category == .decision ? "Installed. This experimental model runs on this Mac when requested." : "Installed and ready for chat.")
                        case .checking: Text("Checking local model…")
                        case .failed(let message): Text(message).foregroundStyle(.red)
                        case .available, .downloading: Text("Download this model before adding it as a provider.")
                        }
                    }
                    if category == .llm && store.registry.defaultConnectionId != nil {
                        Section {
                            Toggle("Use as Default Provider", isOn: $makeDefault)
                                .disabled(existing?.id == store.registry.defaultConnectionId)
                        }
                    }
                    if let error { Section {} footer: { Text(error).foregroundStyle(.red) } }
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
            if existing == nil || name == old.name { name = suggestedName(new.name) }
            endpoint = new.baseURL; apiKey = ""; isAPIKeyVisible = false
            modelID = new.category == .decision ? "jev-latest" : ""
            models = []; error = nil; discoveryFinished = false; refreshID = 0
        }
        .onChange(of: category) { _, new in
            preset = new == .decision ? .adapter(.jev) : .adapter(.openAI)
            makeDefault = new == .llm && store.registry.defaultConnectionId == nil
        }
        .task(id: preset.provider) {
            nativeModel.cancel()
            if nativeModel.category != category {
                nativeModel = NativeLocalModel(agent: store.agent, category: category)
            }
            if managesLocalModels { nativeModel.refresh() }
        }
        .sheet(isPresented: $showsDownload, onDismiss: { nativeModel.refresh() }) {
            LocalModelDownloadSheet(agent: store.agent, modelID: nativeModel.selectedModelID, category: category)
        }
        .onDisappear { nativeModel.cancel(); saveTask?.cancel() }
        .task(id: discoveryKey) { await discover() }
    }

    @ViewBuilder private var remoteSections: some View {
        Section {
            if category == .llm {
                LabeledContent(preset.provider == .openAICompatible ? "Endpoint" : "Base URL") {
                    TextField("Endpoint", text: $endpoint, prompt: Text(endpointPrompt))
                        .labelsHidden().autocorrectionDisabled()
                }
                .help(preset.provider == .openAICompatible ? "The OpenAI-compatible API endpoint, including its version path." : "Leave blank to use the provider’s default endpoint.")
            }
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
            }.help("API keys are stored in macOS Keychain.")
            if category == .decision {
                LabeledContent("Model", value: "Jev · jev-latest")
                TextField("Connection name", text: $name)
            } else {
                LabeledContent("Models") {
                    HStack(spacing: 8) {
                        Text(isDiscovering ? "Loading…" : "\(models.count) available").foregroundStyle(.secondary)
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
            if category == .decision {
                Text("Jev evaluates typed questions through TypeSafe. The key is stored in Keychain; decisions are not sent to chat automatically.")
            }
            if category == .decision, let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            } else if let discoveryError {
                Label(discoveryError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if discoveryFinished, models.isEmpty {
                Text("No models were returned by this model provider.").foregroundStyle(.secondary)
            }
        }
        if category == .llm {
            Section {
                if showsAdvanced {
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
                if showsAdvanced { Text("Enter a model ID for endpoints without a model catalog.") }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
    }

    private var managesLocalModels: Bool { preset.provider.isNative }
    private var primaryActionTitle: String { existing == nil ? "Add Provider" : "Save" }
    private var apiKeyTitle: String { preset.requiresAPIKey ? "API Key" : "API Key (Optional)" }
    private var endpointPrompt: String { preset.baseURL.isEmpty ? preset.provider.endpoint : preset.baseURL }
    private var keepsSavedKey: Bool {
        guard let existing, existing.provider == preset.provider else { return false }
        let old = existing.baseURL?.isEmpty == false ? existing.baseURL! : existing.provider.endpoint
        let current = endpoint.isEmpty ? preset.provider.endpoint : endpoint
        return old.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == current.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private var keyPrompt: String { keepsSavedKey ? "Leave blank to keep a saved key" : "Enter API key" }
    private var canSave: Bool {
        !isSaving && (!managesLocalModels || nativeModel.state == .installed)
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!preset.requiresAPIKey || !apiKey.isEmpty || keepsSavedKey)
            && (preset.provider != .openAICompatible || !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private var discoveryKey: DiscoveryKey { DiscoveryKey(provider: preset, endpoint: endpoint, apiKey: apiKey, refresh: refreshID) }
    private var connection: ProviderConnection {
        ProviderConnection(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), provider: preset.provider,
                           baseURL: managesLocalModels || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                           modelID: managesLocalModels ? nativeModel.selectedModelID : category == .decision ? "jev-latest" : modelID.trimmingCharacters(in: .whitespacesAndNewlines))
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
        isDiscovering = false; discoveryError = nil; discoveryFinished = false; models = []
        guard !preset.requiresAPIKey || !apiKey.isEmpty || keepsSavedKey else {
            if refreshID > 0 { discoveryError = "Enter an API key, then refresh." }; return
        }
        guard preset.provider != .openAICompatible || !endpoint.isEmpty else {
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
            models = response.models; discoveryFinished = true
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
                try await store.save(connection, key: apiKey, makeDefault: makeDefault)
                try Task.checkCancellation()
                apiKey = ""; dismiss()
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct DiscoveryKey: Hashable {
    let provider: AIProviderPreset
    let endpoint: String
    let apiKey: String
    let refresh: Int
}
