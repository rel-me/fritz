import Fritz
import SwiftUI

public enum ModelsLocation: String, CaseIterable, Identifiable {
    case local, remote
    public var id: Self { self }
    public var title: String { self == .local ? "Local Models" : "Remote Models" }
    public func contains(_ model: ChatModelOption) -> Bool {
        AIProviderCategory.local.contains(model.displayProvider) == (self == .local)
    }
}

/// One catalog list per location. Catalog membership never implies readiness.
public struct ModelsCatalogView: View {
    @Bindable private var store: ModelsStore
    @Bindable private var runtime: ModelsLocalRuntime
    let location: ModelsLocation
    @State private var query = ""
    @State private var checkedInventory = false
    @State private var selection: String?
    @State private var setup: ChatModelOption?
    @State private var providerSetup: RemoteProviderRow?
    @State private var showsCustomSetup = false
    @State private var showsImport = false
    @State private var export: ProviderTextExport?
    @State private var confirmsExport = false
    @State private var removing: ProviderConnection?

    public init(store: ModelsStore, runtime: ModelsLocalRuntime, location: ModelsLocation) {
        self.store = store; self.runtime = runtime; self.location = location
    }

    private var models: [ChatModelOption] {
        store.availableModels.filter { location.contains($0) && (query.isEmpty
            || $0.displayName.localizedStandardContains(query)
            || $0.modelID.localizedStandardContains(query)) }
            .enumerated().sorted { lhs, rhs in
                let left = store.recentIDs.firstIndex(of: lhs.element.id) ?? Int.max
                let right = store.recentIDs.firstIndex(of: rhs.element.id) ?? Int.max
                return left == right ? lhs.offset < rhs.offset : left < right
            }.map(\.element)
    }
    private var selected: ChatModelOption? { models.first { $0.id == selection } }
    private var connections: [ProviderConnection] {
        store.connections.filter {
            AIProviderCategory.local.contains(AIProviderPreset.matching(provider: $0.provider, baseURL: $0.baseURL)) == (location == .local)
        }
    }

    private struct RemoteProviderRow: Identifiable {
        let id: String
        let name: String
        let preset: AIProviderPreset
        let connection: ProviderConnection?
        let models: [ChatModelOption]
        var modelNames: String { models.map(\.displayName).joined(separator: ", ") }
    }

    private var remoteProviders: [RemoteProviderRow] {
        let available = store.availableModels.filter { ModelsLocation.remote.contains($0) }
        let recents = store.recentIDs
        func row(_ preset: AIProviderPreset, connection: ProviderConnection?) -> RemoteProviderRow {
            let candidates = available.filter {
                $0.displayProvider == preset && ($0.connectionID == nil || $0.connectionID == connection?.id)
            }
            let ordered = candidates.enumerated().sorted { lhs, rhs in
                let left = recents.firstIndex(of: lhs.element.id) ?? Int.max
                let right = recents.firstIndex(of: rhs.element.id) ?? Int.max
                return left == right ? lhs.offset < rhs.offset : left < right
            }.map(\.element)
            var seen = Set<String>()
            return RemoteProviderRow(id: connection?.id.uuidString ?? "provider:\(preset.id)",
                                     name: connection?.name ?? preset.displayName, preset: preset,
                                     connection: connection, models: ordered.filter { seen.insert($0.modelID).inserted })
        }
        var rows = connections.map { row(AIProviderPreset.matching(provider: $0.provider, baseURL: $0.baseURL), connection: $0) }
        for preset in AIProviderPreset.allCases where AIProviderCategory.remote.contains(preset) {
            if !rows.contains(where: { $0.preset == preset }) { rows.append(row(preset, connection: nil)) }
        }
        return rows.filter { query.isEmpty || $0.name.localizedStandardContains(query)
            || $0.preset.displayName.localizedStandardContains(query)
            || $0.models.contains { $0.displayName.localizedStandardContains(query) || $0.modelID.localizedStandardContains(query) } }
    }

    private var selectedProvider: RemoteProviderRow? { remoteProviders.first { $0.id == selection } }

    private var remoteProviderTable: some View {
        Table(remoteProviders, selection: $selection) {
            TableColumn("Provider") { row in
                Text(row.name).lineLimit(1).truncationMode(.tail)
            }.width(min: 180, ideal: 240)
            TableColumn("Models") { row in
                Text(row.modelNames).lineLimit(1).truncationMode(.tail).help(row.modelNames)
            }.width(min: 240, ideal: 480)
            TableColumn("Status") { row in
                Text(row.connection.map { store.discoveryErrors[$0.id] == nil ? "Ready" : "Needs Setup" } ?? "Setup Required")
                    .foregroundStyle(.secondary)
            }.width(min: 120, ideal: 140)
        }
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .accessibilityLabel("Remote Providers")
        .contextMenu(forSelectionType: String.self) { ids in
            if let row = remoteProviders.first(where: { ids.contains($0.id) }) {
                Button("Set Up Provider…") { providerSetup = row }
                if let connection = row.connection {
                    Button("Remove Connection…", role: .destructive) { removing = connection }
                }
            }
        } primaryAction: { ids in
            providerSetup = remoteProviders.first { ids.contains($0.id) }
        }
    }

    private var localModelTable: some View {
        Table(models, selection: $selection) {
            TableColumn("Name") { model in
                Text(model.displayName).lineLimit(1).truncationMode(.tail).help(model.modelID)
            }.width(min: 230, ideal: 350)
            TableColumn("Type") { model in Text(model.category == .llm ? "LLM" : "Decision") }
                .width(75)
            TableColumn("Status") { model in Text(status(model)).foregroundStyle(.secondary) }
                .width(min: 120, ideal: 140)
        }
        .accessibilityLabel("Local Models")
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let model = models.first(where: { $0.id == id }) {
                Button("Set Up Model…") { setup = model }
                if let connectionID = model.connectionID,
                   let connection = store.connections.first(where: { $0.id == connectionID }) {
                    Button("Remove Connection…", role: .destructive) { removing = connection }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first { setup = models.first { $0.id == id } }
        }
    }

    private var nativeLocalContent: some View {
        VStack(spacing: 0) {
            localModelTable
            if let error = store.error ?? runtime.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled).padding()
            }
        }
        .navigationTitle("Local Models")
        .searchable(text: $query, placement: .toolbar, prompt: "Search Models")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Connect Local Service…", systemImage: "plus") { showsCustomSetup = true }
                    .help("Connect Local Service…")
                Button("Set Up Model…", systemImage: "slider.horizontal.3") { setup = selected }
                    .disabled(selected == nil)
                    .help("Set Up Model…")
                Menu {
                    Button("Import…") { showsImport = true }
                    Button("Export…") { confirmsExport = true }.disabled(connections.isEmpty)
                } label: { Label("Import and Export", systemImage: "ellipsis") }
                .help("Import and Export")
            }
            ToolbarItem(placement: .status) {
                if !checkedInventory || store.isLoading || runtime.isLoading {
                    ProgressView().controlSize(.small).accessibilityLabel("Loading models")
                }
            }
        }
    }

    private var remoteContent: some View {
        VStack(spacing: 0) {
            ModelManagementHeader(location.title, background: ModelsConfigurationStyle.workspaceBackground) {
                Menu {
                    Button("Import…") { showsImport = true }
                    Button("Export…") { confirmsExport = true }.disabled(connections.isEmpty)
                } label: { Label("Import and Export", systemImage: "ellipsis") }
                .labelStyle(.iconOnly).menuIndicator(.hidden)
                .buttonStyle(FritzButtonStyle(.floating, shape: .circle))
            }
            TextField("Search providers", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20).padding(.bottom, 12)
            remoteProviderTable
            if let error = store.error {
                Text(error).foregroundStyle(.orange).textSelection(.enabled).padding(12)
            }
            Divider()
            HStack {
                Button("New Remote Model…") { showsCustomSetup = true }
                if store.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Set Up Provider…") { providerSetup = selectedProvider }
                    .disabled(selectedProvider == nil)
                    .buttonStyle(FritzButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(ModelsConfigurationStyle.workspaceBackground)
        .buttonStyle(FritzButtonStyle())
    }

    public var body: some View {
        Group {
            if location == .local { nativeLocalContent } else { remoteContent }
        }
        .sheet(item: $setup, onDismiss: { Task { await runtime.refresh() } }) { model in
            let connection = store.setupConnection(for: model)
            ModelsProviderEditor(store: store, localModels: runtime, existing: connection,
                                 initialModel: model.connectionID != nil && connection?.modelID == model.modelID ? nil : model,
                                 providerOptions: location == .local ? [model.displayProvider] : nil)
        }
        .sheet(item: $providerSetup) { row in
            ModelsProviderEditor(store: store, localModels: runtime, existing: row.connection,
                                 initialPreset: row.preset, remoteOnly: true)
        }
        .sheet(isPresented: $showsCustomSetup) {
            ModelsProviderEditor(store: store, localModels: runtime, existing: nil,
                                 initialPreset: location == .local ? .adapter(.ollama) : nil,
                                 remoteOnly: location == .remote,
                                 providerOptions: location == .local ? [.adapter(.ollama)] : nil)
        }
        .sheet(isPresented: $showsImport) { ConfigurationTransferSheet(store: store) }
        .sheet(item: $export) { ConfigurationTransferSheet(store: store, exported: $0) }
        .confirmationDialog("Export", isPresented: $confirmsExport) {
            Button("Export Without Keys") { exportConnections(keys: false) }
            Button("Export Including API Keys") { exportConnections(keys: true) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Included API keys will be readable in the export.") }
        .confirmationDialog("Remove this connection?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        )) {
            Button("Remove Connection", role: .destructive) {
                guard let connection = removing else { return }
                removing = nil
                Task {
                    await store.remove(connection)
                    if connection.provider == .fritz && !store.connections.contains(where: { $0.id == connection.id }) {
                        runtime.stop(connection.modelID)
                    }
                }
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { Text("All models using this connection will need setup again.") }
        .task {
            await runtime.refresh()
            guard !Task.isCancelled else { return }
            checkedInventory = true
            await store.refresh()
        }
    }

    private func status(_ model: ChatModelOption) -> String {
        if let id = model.connectionID {
            return store.discoveryErrors[id] == nil ? "Ready" : "Needs Setup"
        }
        if model.provider == .fritz {
            if !checkedInventory || runtime.isLoading { return "Checking…" }
            return runtime.installedIDs.contains(model.modelID) ? "Downloaded" : "Not Downloaded"
        }
        return "Setup Required"
    }
    private func exportConnections(keys: Bool) {
        do { export = ProviderTextExport(text: try store.exportProviders(connections, includeKeys: keys), includesKeys: keys) }
        catch { store.error = error.localizedDescription }
    }
}
