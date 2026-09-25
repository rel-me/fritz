import Fritz
import SwiftUI

struct ProviderEditorSelection: Identifiable {
    let id = UUID()
    var connection: ProviderConnection? = nil
    var category: AIModelCategory = .llm
}

struct ProvidersView: View {
    @Bindable var store: ProviderStore
    @Binding var editor: ProviderEditorSelection?
    var openLocalModels: () -> Void
    @State private var selectedID: UUID?
    @State private var deleting: ProviderConnection?
    @State private var category: AIModelCategory = .llm

    private var visibleConnections: [ProviderConnection] {
        store.connections.filter { $0.category == category }
    }

    var body: some View {
        VStack(spacing: 0) {
            FritzManagementHeader("Model Providers", description: "Choose an LLM for chat or a decision model for typed judgments.") {
                HStack(spacing: 6) {
                    Button("Add") { editor = ProviderEditorSelection(category: category) }
                        .buttonStyle(FritzButtonStyle(.floatingPrimary)).help("Add Provider")
                        .accessibilityLabel("Add Provider")
                    Button("Edit Provider", systemImage: "square.and.pencil") {
                        if let selectedConnection { editor = ProviderEditorSelection(connection: selectedConnection, category: category) }
                    }
                    .labelStyle(.iconOnly).disabled(selectedConnection == nil).help("Edit Provider")
                    Button("Refresh Models", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                        .labelStyle(.iconOnly).disabled(store.isLoading).help("Refresh Models")
                    Button("Local Models", systemImage: "server.rack", action: openLocalModels)
                        .labelStyle(.iconOnly).help("Manage Local Models")
                        .disabled(category == .decision)
                }
                .buttonStyle(FritzButtonStyle(.floating))
                .modifier(FritzGlassControlGroup())
            }

            Picker("Model category", selection: $category) {
                ForEach(AIModelCategory.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .padding(.vertical, 10)
            .onChange(of: category) { _, _ in selectedID = nil }

            Table(visibleConnections, selection: $selectedID) {
                TableColumn("Name") { connection in
                    HStack(spacing: 6) {
                        Text(connection.providerDisplayName).lineLimit(1).truncationMode(.tail)
                            .help(connection.name)
                        if let warning = store.discoveryErrors[connection.id] {
                            Button { editor = ProviderEditorSelection(connection: connection, category: category) } label: {
                                chip("Needs Setup", color: .orange)
                            }
                            .buttonStyle(FritzButtonStyle(.inline)).help(warning)
                            .accessibilityLabel("\(connection.providerDisplayName): \(warning)")
                        } else if store.isLoading {
                            chip("Loading", color: .secondary)
                        } else {
                            chip("Ready", color: .green)
                        }
                        if [.fritz, .ollama].contains(connection.provider) { chip("Local") }
                        if connection.id == store.registry.defaultConnectionId { chip("Default") }
                    }
                }.width(min: 260, ideal: 340, max: .infinity)
                TableColumn("Models") { connection in
                    if let models = store.catalog[connection.id] {
                        let names = models.map(\.displayName).joined(separator: ", ")
                        Text(names.isEmpty ? "No models" : names).lineLimit(1).truncationMode(.tail).help(names)
                    } else {
                        Text(store.isLoading ? "Loading…" : connection.modelID.isEmpty ? "—" : connection.modelID)
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }.width(min: 100, max: .infinity)
            }
            .fritzListSurface()
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let connection = store.connections.first(where: { ids.contains($0.id) }) {
                    Button("Edit Provider", systemImage: "pencil") { editor = ProviderEditorSelection(connection: connection, category: category) }
                    if category == .llm {
                        Button("Make Default", systemImage: "checkmark.circle") { Task { await store.makeDefault(connection) } }
                            .disabled(connection.id == store.registry.defaultConnectionId)
                    }
                    Divider()
                    Button("Delete Provider", role: .destructive) { deleting = connection }
                }
            } primaryAction: { ids in
                if let connection = store.connections.first(where: { ids.contains($0.id) }) {
                    editor = ProviderEditorSelection(connection: connection, category: category)
                }
            }
            .onDeleteCommand { deleting = selectedConnection }
            .overlay {
                if visibleConnections.isEmpty {
                    ContentUnavailableView(category == .llm ? "No LLM Providers" : "No Decision Models",
                                           systemImage: "cpu",
                                           description: Text(category == .llm ? "Add an LLM service or local model." : "Add Jev to evaluate typed decisions."))
                }
            }
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled).padding(12)
            }
        }
        .background(FritzWindowStyle.workspaceBackground)
        .confirmationDialog("Delete this provider?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            if let deleting {
                Button("Delete \(deleting.providerDisplayName)", role: .destructive) { Task { await store.remove(deleting) }; self.deleting = nil }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("This removes the connection and its saved key from Fritz.") }
        .buttonStyle(FritzButtonStyle())
    }

    private func chip(_ title: String, color: Color = .secondary) -> some View {
        Text(title).font(.caption).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule()).fixedSize()
    }
    private var selectedConnection: ProviderConnection? { store.connections.first { $0.id == selectedID } }
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
    @State private var addsAfterInstallation = false
    @State private var saveTask: Task<Void, Never>?

    init(store: ProviderStore, existing: ProviderConnection?, initialCategory: AIModelCategory = .llm) {
        self.store = store; self.existing = existing
        let category = existing?.category ?? initialCategory
        _category = State(initialValue: category)
        _id = State(initialValue: existing?.id ?? UUID())
        _nativeModel = State(initialValue: NativeLocalModel(agent: store.agent, modelID: existing?.modelID))
        let baseName = category == .decision ? "Jev" : "OpenAI"
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
        VStack(spacing: 0) {
            FritzManagementHeader(existing == nil ? "New Provider" : "Edit Provider")
            Divider()
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
                    NativeLocalModelSection(modelID: Binding(
                        get: { nativeModel.selectedModelID },
                        set: { addsAfterInstallation = false; nativeModel.select($0) }
                    ), state: nativeModel.state, hardware: .current)
                    if store.registry.defaultConnectionId != nil {
                        Section {
                            Toggle("Use as Default Provider", isOn: $makeDefault)
                                .disabled(nativeModel.state.isBusy || existing?.id == store.registry.defaultConnectionId)
                        }
                    }
                    if let error { Section {} footer: { Text(error).foregroundStyle(.red) } }
                } else {
                    remoteSections
                }
            }
            .fritzSettingsFormStyle().disabled(isSaving)
            Divider()
            HStack(spacing: 8) {
                if managesLocalModels { Link("Model license", destination: nativeModel.selectedModel.licenseURL) }
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { addsAfterInstallation = false; nativeModel.cancel(); dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                Button(primaryActionTitle, action: save)
                    .buttonStyle(FritzButtonStyle(.primary)).keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(FritzWindowStyle.workspaceBackground)
        }
        .frame(width: 600, height: managesLocalModels ? 340 + (store.connections.isEmpty ? 0 : 40) : category == .decision ? 430 : 400 + (showsAdvanced ? 150 : 0) + (store.connections.isEmpty ? 0 : 32) + (discoveryError == nil ? 0 : 60))
        .background(FritzWindowStyle.contentBackground)
        .buttonStyle(FritzButtonStyle())
        .interactiveDismissDisabled(isSaving)
        .onChange(of: preset) { old, new in
            addsAfterInstallation = false; nativeModel.cancel()
            if existing == nil || name == old.name { name = suggestedName(new.name) }
            endpoint = new.baseURL; apiKey = ""; isAPIKeyVisible = false
            modelID = new.category == .decision ? "jev-latest" : ""
            models = []; error = nil; discoveryFinished = false; refreshID = 0
        }
        .onChange(of: category) { _, new in
            preset = new == .decision ? .adapter(.jev) : .adapter(.openAI)
            makeDefault = new == .llm && store.registry.defaultConnectionId == nil
        }
        .task(id: managesLocalModels) {
            addsAfterInstallation = false
            if managesLocalModels { nativeModel.refresh() } else { nativeModel.cancel() }
        }
        .onChange(of: nativeModel.state) { _, state in
            if managesLocalModels, state == .installed, addsAfterInstallation {
                addsAfterInstallation = false
                save()
            }
        }
        .onDisappear { addsAfterInstallation = false; nativeModel.cancel(); saveTask?.cancel() }
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
                DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
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
            } footer: {
                if showsAdvanced { Text("Enter a model ID for endpoints without a model catalog.") }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
    }

    private var managesLocalModels: Bool { preset.provider == .fritz }
    private var primaryActionTitle: String {
        guard managesLocalModels else { return existing == nil ? "Add Provider" : "Save" }
        if nativeModel.state.isBusy { return "Installing…" }
        if nativeModel.state == .installed { return existing == nil ? "Add Model" : "Save" }
        if case .failed = nativeModel.state { return "Retry Download & Add" }
        return "Download & Add"
    }
    private var apiKeyTitle: String { preset.requiresAPIKey ? "API Key" : "API Key (Optional)" }
    private var endpointPrompt: String { preset.baseURL.isEmpty ? preset.provider.endpoint : preset.baseURL }
    private var keepsSavedKey: Bool {
        guard let existing, existing.provider == preset.provider else { return false }
        let old = existing.baseURL?.isEmpty == false ? existing.baseURL! : existing.provider.endpoint
        let current = endpoint.isEmpty ? preset.provider.endpoint : endpoint
        return old.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == current.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private var keyPrompt: String { keepsSavedKey ? "Saved in Keychain" : "Enter API key" }
    private var canSave: Bool {
        !isSaving && !nativeModel.state.isBusy && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!preset.requiresAPIKey || !apiKey.isEmpty || keepsSavedKey)
            && (preset.provider != .openAICompatible || !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private var discoveryKey: DiscoveryKey { DiscoveryKey(provider: preset, endpoint: endpoint, apiKey: apiKey, refresh: refreshID) }
    private var connection: ProviderConnection {
        ProviderConnection(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), provider: preset.provider,
                           baseURL: managesLocalModels || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                           modelID: category == .decision ? "jev-latest" : managesLocalModels ? nativeModel.selectedModelID : modelID.trimmingCharacters(in: .whitespacesAndNewlines))
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
        if managesLocalModels, nativeModel.state != .installed {
            addsAfterInstallation = true
            error = nil
            nativeModel.install()
            return
        }
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
