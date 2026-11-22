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
    @State private var issue: String?
    @Environment(\.dismiss) private var dismiss

    private var savedConnection: ProviderConnection? {
        store.workspace.providers.first { $0.id == connection.id }
    }

    private var destinationChanged: Bool {
        savedConnection?.kind != connection.kind || savedConnection?.endpoint != endpoint
    }

    private var endpoint: String {
        connection.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
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
                if connection.kind == .compatible || connection.kind == .fritzRemote {
                    TextField(connection.kind == .fritzRemote ? "Tunnel URL" : "Endpoint URL",
                              text: $connection.customEndpoint,
                              prompt: Text(connection.kind == .fritzRemote ? "https://mac.example.com" : "https://example.com/v1"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("provider-endpoint")
                }
                SecureField(credentialTitle, text: $replacement)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let issue {
                        Text(issue).foregroundStyle(.red)
                    }
                    if connection.kind == .fritzRemote {
                        Text("Get the access key from Settings → Service → Remote Model Access on your Mac.")
                    }
                    if destinationChanged {
                        let destination = URLComponents(string: endpoint)?.host ?? connection.kind.title
                        Text("By tapping Save, you allow Fritz to send your conversation history to \(destination) when you send a message or retry a reply.")
                    }
                }
            }
        }
        .navigationTitle("Provider")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
            }
        }
        .onChange(of: connection.kind) { _, _ in
            replacement = ""
            issue = nil
        }
        .onChange(of: connection.customEndpoint) { _, _ in
            replacement = ""
            issue = nil
        }
        .onChange(of: replacement) { _, _ in issue = nil }
    }

    private var credentialTitle: String {
        let replacingKey = connection.credentialID != nil && !destinationChanged
        if connection.kind == .fritzRemote {
            return replacingKey ? "Replace Access Key" : "Access Key"
        }
        return replacingKey ? "Replace API Key" : "API Key"
    }

    private func save() {
        var updated = connection
        if destinationChanged { updated.defaultModel = "" }
        if savedConnection?.kind != connection.kind { updated.name = connection.kind.title }
        do {
            try store.saveProvider(updated, replacement: replacement)
            dismiss()
        } catch {
            issue = error.localizedDescription
        }
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
                ModelField(model: $model, emptyMessage: provider.kind == .fritzRemote
                           ? "No installed chat models on the Mac."
                           : "The provider returned an empty catalog. Enter a model ID if you know it.") {
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
    let emptyMessage: String
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
                Text(emptyMessage)
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
