import SwiftUI
import Textual

struct ProvidersView: View {
    let store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemoval: ProviderConnection?

    var body: some View {
        List {
            Section {
                ForEach(store.workspace.providers) { connection in
                    NavigationLink {
                        ProviderEditor(store: store, connection: connection)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connection.name)
                            Text(connection.kind.title)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Remove", systemImage: "trash", role: .destructive) { confirmRemoval = connection }
                    }
                }
                NavigationLink {
                    ProviderEditor(store: store, connection: ProviderConnection())
                } label: {
                    Label("Add Provider", systemImage: "plus")
                }
            } footer: {
                Text("API keys are stored in the iPhone Keychain. Chat messages are sent to the provider selected for that chat.")
            }
            NavigationLink("Privacy Policy") { PrivacyPolicyView() }
        }
        .navigationTitle("Providers")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .confirmationDialog("Remove Provider?", isPresented: Binding(
            get: { confirmRemoval != nil },
            set: { if !$0 { confirmRemoval = nil } }
        ), titleVisibility: .visible, presenting: confirmRemoval) { connection in
            Button("Remove Provider", role: .destructive) { store.deleteProvider(connection.id) }
        } message: { connection in
            Text("Chats that use \(connection.name) will need another provider for new replies.")
        }
    }
}

private struct ProviderEditor: View {
    let store: ChatStore
    @State var connection: ProviderConnection
    @State private var replacement = ""
    @State private var credentialRevision = UUID()
    @State private var issue: String?
    @State private var allowSharing = false
    @Environment(\.dismiss) private var dismiss

    private var needsConsent: Bool {
        let saved = store.workspace.providers.first { $0.id == connection.id }
        return saved?.kind != connection.kind || saved?.endpoint != connection.endpoint
    }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $connection.kind) {
                    ForEach(ProviderKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .accessibilityIdentifier("provider-kind")
                TextField("Connection Name", text: $connection.name, prompt: Text(connection.kind.title))
                if connection.kind == .compatible {
                    TextField("Endpoint URL", text: $connection.customEndpoint, prompt: Text("https://example.com/v1"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("provider-endpoint")
                }
                SecureField(connection.credentialID == nil ? "API Key" : "Replace API Key", text: $replacement)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                if connection.kind == .compatible {
                    Text("Use the base URL for the provider’s OpenAI-compatible API. Enter a key if the provider requires one.")
                }
            }
            ModelField(model: $connection.defaultModel, load: loadModels)
                .id(DiscoveryInput(endpoint: connection.endpoint, kind: connection.kind, credential: credentialRevision))
            if needsConsent {
                Section {
                    Toggle("Allow Chat Sharing", isOn: $allowSharing)
                } footer: {
                    let host = URLComponents(string: connection.endpoint)?.host
                    Text("When you send a message or retry a reply, Fritz shares that conversation’s history with \(host ?? "this provider").")
                }
            }
            Section {
                if let issue {
                    Text(issue).foregroundStyle(.red)
                }
                Button("Save Provider") {
                    do {
                        try store.saveProvider(connection, replacement: replacement)
                        dismiss()
                    } catch {
                        issue = error.localizedDescription
                    }
                }
                .disabled(needsConsent && !allowSharing)
            }
        }
        .navigationTitle("Provider")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: connection.kind) { _, _ in
            connection.defaultModel = ""
            replacement = ""
            allowSharing = false
        }
        .onChange(of: connection.customEndpoint) { _, _ in
            connection.defaultModel = ""
            allowSharing = false
        }
        .onChange(of: replacement) { _, _ in credentialRevision = UUID() }
    }

    private struct DiscoveryInput: Hashable {
        let endpoint: String
        let kind: ProviderKind
        let credential: UUID
    }

    private func loadModels() async throws -> [ProviderRuntime.Model] {
        var connection = connection
        connection.customEndpoint = connection.customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = try store.key(for: connection, replacement: replacement)
        try connection.validate(key: key)
        return try await ProviderRuntime.models(for: connection, key: key)
    }
}

struct ChatModelView: View {
    let store: ChatStore
    let chat: Conversation
    @State private var providerID: UUID?
    @State private var model: String
    @State private var issue: String?
    @Environment(\.dismiss) private var dismiss

    init(store: ChatStore, chat: Conversation) {
        self.store = store
        self.chat = chat
        let saved = store.workspace.providers.first { $0.id == chat.providerID }
        let selection = saved ?? store.workspace.providers.first
        _providerID = State(initialValue: selection?.id)
        _model = State(initialValue: saved == nil ? (selection?.defaultModel ?? "") : chat.model)
    }

    private var provider: ProviderConnection? {
        store.workspace.providers.first { $0.id == providerID }
    }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $providerID) {
                    Text("Choose Provider").tag(nil as UUID?)
                    ForEach(store.workspace.providers) { provider in
                        Text(provider.name).tag(Optional(provider.id))
                    }
                }
            }
            if let provider {
                ModelField(model: $model) {
                    let key = try ProviderKeychain.read(provider.credentialID)
                    return try await ProviderRuntime.models(for: provider, key: key)
                }
                .id(provider.id)
            }
            if let issue {
                Section { Text(issue).foregroundStyle(.red) }
            }
            if let provider, chat.providerID != provider.id && !chat.messages.isEmpty {
                Section {
                    Text("Your earlier messages will be sent to \(provider.name) when you send the next message.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Choose Model")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Use Model") {
                    guard let providerID else { return }
                    do {
                        try store.setModel(provider: providerID, model: model, chatID: chat.id)
                        dismiss()
                    } catch {
                        issue = error.localizedDescription
                    }
                }
                .disabled(provider == nil || model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onChange(of: providerID) { _, _ in model = provider?.defaultModel ?? "" }
    }
}

private struct ModelField: View {
    @Binding var model: String
    let load: @MainActor () async throws -> [ProviderRuntime.Model]
    @State private var results: [ProviderRuntime.Model]?
    @State private var issue: String?
    @State private var query: UUID?
    @State private var loading = false

    var body: some View {
        Section {
            TextField("Model ID", text: $model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("model-id")
            Button("Load Models", systemImage: "arrow.down.circle") {
                issue = nil
                results = nil
                loading = true
                query = UUID()
            }
            .disabled(loading)
            if let results, !results.isEmpty {
                NavigationLink {
                    ModelResults(models: results) { model = $0 }
                } label: {
                    Text("Choose from \(results.count) models")
                }
            }
        } header: {
            Text("Model")
        } footer: {
            if loading {
                ProgressView("Loading models")
            } else if let issue {
                Text(issue).foregroundStyle(.red)
            } else if results?.isEmpty == true {
                Text("The provider returned an empty catalog. Enter a model ID if you know it.")
            }
        }
        .task(id: query) {
            guard query != nil else { return }
            do {
                let models = try await load()
                try Task.checkCancellation()
                results = models
                loading = false
                query = nil
            } catch {
                guard !Task.isCancelled else { return }
                issue = error.localizedDescription
                loading = false
                query = nil
            }
        }
    }
}

private struct ModelResults: View {
    let models: [ProviderRuntime.Model]
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        List(models.filter {
            search.isEmpty || $0.id.localizedStandardContains(search) || $0.displayName.localizedStandardContains(search)
        }) { entry in
            Button {
                choose(entry.id)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.displayName)
                    if entry.id != entry.displayName {
                        Text(entry.id).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Models")
        .searchable(text: $search, prompt: "Search models")
    }
}


private struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            if let url = Bundle.main.url(forResource: "ios-privacy", withExtension: "md"),
               let policy = try? String(contentsOf: url, encoding: .utf8) {
                StructuredText(markdown: policy)
                    .textual.structuredTextStyle(.gitHub)
                    .padding(20)
            }
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
