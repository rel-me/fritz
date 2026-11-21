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
    @State private var category: AIModelCategory?
    @State private var downloadFilter: DownloadFilter = .all
    @State private var runnableOnly = false
    @State private var scoreFilter: LocalModelScoreFilter = .all
    @State private var scoreOrder: [LocalModelScoreComparator<LocalModelRow>] = []
    private let hardware = LocalModelHardware.current
    @State private var checkedInventory = false
    @State private var installedDecisionIDs: Set<String>?
    @State private var decisionInventoryError: String?
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

    private enum DownloadFilter: String, CaseIterable {
        case all = "All Download States"
        case downloaded = "Downloaded"
        case notDownloaded = "Not Downloaded"
    }

    private func isDownloaded(_ model: ChatModelOption) -> Bool? {
        if model.category == .decision { return installedDecisionIDs?.contains(model.modelID) }
        guard checkedInventory else { return nil }
        return runtime.installedIDs.contains(model.modelID)
    }

    private func matchesDownloadFilter(_ model: ChatModelOption) -> Bool {
        switch downloadFilter {
        case .all: true
        case .downloaded: isDownloaded(model) == true
        case .notDownloaded: isDownloaded(model) == false
        }
    }

    private struct LocalModelRow: Identifiable {
        let model: ChatModelOption
        let descriptor: NativeModelDescriptor?
        var id: String { model.id }
        var scorePoints: Int? { descriptor?.benchmarkScore?.points }
    }

    private var localRows: [LocalModelRow] {
        let descriptors = Dictionary(uniqueKeysWithValues: store.nativeModelCatalog.map { ($0.id, $0) })
        let recents = store.recentIDs
        let rows = store.availableModels.filter {
            location.contains($0) && (category == nil || $0.category == category)
                && matchesDownloadFilter($0) && (query.isEmpty
                    || $0.displayName.localizedStandardContains(query)
                    || $0.modelID.localizedStandardContains(query))
        }.map { LocalModelRow(model: $0, descriptor: descriptors[$0.modelID]) }
            .filter { row in
                scoreFilter.includes(row.scorePoints)
                    && (!runnableOnly || row.descriptor.map(hardware.canRun) == true)
            }
            .sorted {
                let left = recents.firstIndex(of: $0.id) ?? Int.max
                let right = recents.firstIndex(of: $1.id) ?? Int.max
                return left < right
            }
        return scoreOrder.isEmpty ? rows : rows.sorted(using: scoreOrder)
    }

    private var selected: ChatModelOption? { localRows.first { $0.id == selection }?.model }
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
        return rows.filter { row in
            (category == nil || row.preset.category == category) && (query.isEmpty
                || row.name.localizedStandardContains(query)
                || row.preset.displayName.localizedStandardContains(query)
                || row.models.contains { $0.displayName.localizedStandardContains(query) || $0.modelID.localizedStandardContains(query) })
        }
    }

    private var selectedProvider: RemoteProviderRow? { remoteProviders.first { $0.id == selection } }

    private var remoteProviderTable: some View {
        Table(remoteProviders, selection: $selection) {
            TableColumn("Provider") { row in
                Text(row.name).lineLimit(1).truncationMode(.tail)
            }.width(240)
            TableColumn("Models") { row in
                Text(row.modelNames).lineLimit(1).truncationMode(.tail).help(row.modelNames)
            }.width(min: 240, max: .infinity)
            TableColumn("Status") { row in
                Text(row.connection.map { store.discoveryErrors[$0.id] == nil ? "Ready" : "Needs Setup" } ?? "Setup Required")
                    .foregroundStyle(.secondary)
            }.width(140)
        }
        .scrollIndicators(.never, axes: .horizontal)
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
        let sessions = runtime.sessions
        let rows = localRows
        return Table(rows, selection: $selection, sortOrder: $scoreOrder) {
            TableColumn("Name") { row in
                Text(row.model.displayName).lineLimit(1).truncationMode(.tail).help(row.model.modelID)
            }.width(min: 230, ideal: 350)
            TableColumn("Type") { row in Text(row.model.category == .llm ? "LLM" : "Decision") }
                .width(75)
            TableColumn("Status") { row in
                let running = sessions[row.model.modelID]?.status == .running
                Text(running ? ModelsRuntimeSession.Status.running.title : status(row.model))
                    .foregroundStyle(running ? .green : .secondary)
            }
            .width(min: 120, ideal: 140)
            TableColumn("Score", sortUsing: LocalModelScoreComparator(points: \.scorePoints)) { row in
                LocalModelScoreCell(score: row.descriptor?.benchmarkScore)
            }
            .width(66)
        }
        .accessibilityLabel("Local Models")
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                Button("Set Up Model…") { setup = row.model }
                if let score = row.descriptor?.benchmarkScore {
                    Link("View Benchmark Result", destination: score.sourceURL)
                }
                if let connectionID = row.model.connectionID,
                   let connection = store.connections.first(where: { $0.id == connectionID }) {
                    Button("Remove Connection…", role: .destructive) { removing = connection }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first { setup = rows.first { $0.id == id }?.model }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            if location == .local { localModelTable } else { remoteProviderTable }
            if let error = store.error ?? (location == .local ? runtime.error ?? decisionInventoryError : nil) {
                Text(error).foregroundStyle(.red).textSelection(.enabled).padding()
            }
        }
        .navigationTitle(location.title)
        .searchable(text: $query, placement: .toolbar,
                    prompt: location == .local ? "Search Models" : "Search Providers")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                filterMenu
                if location == .remote {
                    Button("New Remote Model…", systemImage: "plus") { showsCustomSetup = true }
                        .help("New Remote Model…")
                }
                Button(location == .local ? "Set Up Model…" : "Set Up Provider…", systemImage: "pencil") {
                    if location == .local { setup = selected } else { providerSetup = selectedProvider }
                }
                .disabled(location == .local ? selected == nil : selectedProvider == nil)
                .help(location == .local ? "Set Up Model…" : "Set Up Provider…")
                if location == .remote {
                    Menu {
                        Button("Import…") { showsImport = true }
                        Button("Export…") { confirmsExport = true }.disabled(connections.isEmpty)
                    } label: { Label("Import and Export", systemImage: "ellipsis") }
                    .help("Import and Export")
                }
            }
        }
        .sheet(item: $setup, onDismiss: { Task { await refreshInventory() } }) { model in
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
            ModelsProviderEditor(store: store, localModels: runtime, existing: nil, remoteOnly: true)
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
            if location == .local { await refreshInventory() }
            guard !Task.isCancelled else { return }
            await store.refresh()
        }
    }

    private var filterMenu: some View {
        let isActive = category != nil || downloadFilter != .all || runnableOnly || scoreFilter != .all
        return Menu {
            Picker("Model Type", selection: $category) {
                Text("All Model Types").tag(nil as AIModelCategory?)
                ForEach(AIModelCategory.allCases) { category in
                    Text(category.title).tag(category as AIModelCategory?)
                }
            }
            if location == .local {
                Divider()
                Picker("Download Status", selection: $downloadFilter) {
                    ForEach(DownloadFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                Toggle("Runnable on This Mac", isOn: $runnableOnly)
                    .help("Matches recommended RAM and Metal requirements")
                LocalModelScorePicker(selection: $scoreFilter, catalog: store.nativeModelCatalog)
                Divider()
                Link("Score Methodology", destination: LocalModelScoreCell.methodology)
            }
        } label: {
            Label("Filter Models", systemImage: isActive
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuIndicator(.hidden)
        .help("Filter Models")
    }

    private func refreshInventory() async {
        await runtime.refresh()
        guard !Task.isCancelled else { return }
        checkedInventory = runtime.error == nil
        do {
            let inventory: LocalModelInventory = try await store.agent.request("decisionModels.list")
            guard !Task.isCancelled else { return }
            installedDecisionIDs = inventory.installedIDs
            decisionInventoryError = nil
        } catch {
            guard !Task.isCancelled else { return }
            installedDecisionIDs = nil
            decisionInventoryError = error.localizedDescription
        }
    }

    private func status(_ model: ChatModelOption) -> String {
        if let id = model.connectionID {
            return store.discoveryErrors[id] == nil ? "Ready" : "Needs Setup"
        }
        if let downloaded = isDownloaded(model) { return downloaded ? "Downloaded" : "Not Downloaded" }
        return (model.category == .decision ? decisionInventoryError : runtime.error) == nil
            ? "Checking…" : "Unavailable"
    }
    private func exportConnections(keys: Bool) {
        do { export = ProviderTextExport(text: try store.exportProviders(connections, includeKeys: keys), includesKeys: keys) }
        catch { store.error = error.localizedDescription }
    }
}
