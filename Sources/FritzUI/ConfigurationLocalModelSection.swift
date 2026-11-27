import Fritz
import SwiftUI

struct NativeModelFilters: Equatable {
    var category: AIModelCategory?
    var family: String?
    var runnableOnly = false
    var score: LocalModelScoreFilter = .all

    func models(in catalog: [NativeModelDescriptor], hardware: LocalModelHardware) -> [NativeModelDescriptor] {
        catalog.filter {
            (category == nil || $0.category == category) && (family == nil || $0.family == family)
                && (!runnableOnly || hardware.canRun($0)) && score.includes($0.benchmarkScore?.points)
        }
    }
}

struct ConfigurationLocalModelSection: View {
    @Binding var filters: NativeModelFilters
    @Binding var modelID: String
    let state: LocalModelInstallState
    let hardware: LocalModelHardware
    let catalog: [NativeModelDescriptor]
    let downloads: ModelDownloads

    @State private var scoreOrder: [LocalModelScoreComparator<NativeModelDescriptor>] = []

    private var filteredModels: [NativeModelDescriptor] {
        let models = filters.models(in: catalog, hardware: hardware)
        return scoreOrder.isEmpty ? models : models.sorted(using: scoreOrder)
    }

    private var model: NativeModelDescriptor {
        catalog.first { $0.id == modelID }!
    }

    private var selection: Binding<String?> {
        Binding(
            get: { modelID },
            set: { if let id = $0 { modelID = id } }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            nativeFilters
            Divider()
            Table(filteredModels, selection: selection, sortOrder: $scoreOrder) {
                TableColumn("Name") { model in
                    Text(model.name).lineLimit(1).help(model.name)
                }
                .width(min: 200, ideal: 250)
                TableColumn("Type") { model in
                    Text(model.category == .llm ? "LLM" : "Decision")
                }
                .width(70)
                TableColumn("Size / Status") { entry in
                    HStack(spacing: 6) {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                            .monospacedDigit()
                        if let status = downloads[entry.id]?.activeStatus {
                            Text(status).foregroundStyle(.secondary)
                        } else if entry.id == modelID {
                            Text(statusTitle).foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                }
                .width(min: 160, ideal: 180)
                TableColumn("Hardware Requirements") { model in
                    Text("\(model.memoryGB) GB RAM recommended")
                        .foregroundStyle(hardware.memoryGB < model.memoryGB ? .orange : .secondary)
                }
                .width(min: 195, ideal: 220)
                TableColumn("Score", sortUsing: LocalModelScoreComparator(points: \.benchmarkScore?.points)) { model in
                    LocalModelScoreCell(score: model.benchmarkScore)
                }
                .width(66)
            }
            .accessibilityLabel("Downloadable models")
            .accessibilityIdentifier("native-model-list")
            .overlay {
                if filteredModels.isEmpty {
                    ContentUnavailableView {
                        Label("No matching models", systemImage: "line.3.horizontal.decrease")
                    } description: {
                        Text("Choose another filter to see available models.")
                    } actions: {
                        Button("Clear Filters") { filters = NativeModelFilters() }
                    }
                }
            }

            if filteredModels.contains(where: { $0.id == modelID }),
               state != .available || !hardware.canRun(model) || !hardware.appleSilicon {
                VStack(alignment: .leading, spacing: 6) {
                    if hardware.memoryGB < model.memoryGB {
                        Text("This Mac has \(hardware.memoryGB) GB memory. A smaller model is recommended.")
                    }
                    if !hardware.metalAvailable && hardware.memoryGB >= model.memoryGB && !hardware.canRun(model) {
                        Text("This model requires Metal.")
                    }
                    if !hardware.appleSilicon {
                        Text("Slower on Intel Macs.")
                    }
                    switch state {
                    case .available:
                        EmptyView()
                    case .checking:
                        ProgressView("Checking model…").controlSize(.small)
                    case .installed:
                        Label("Installed", systemImage: "checkmark.circle")
                    case let .downloading(downloaded, total, bytesPerSecond):
                        ModelDownloadProgress(downloaded: downloaded, total: total, bytesPerSecond: bytesPerSecond)
                    case let .failed(message):
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
    }

    private var nativeFilters: some View {
        HStack {
            Picker("Type", selection: $filters.category) {
                Text("All").tag(AIModelCategory?.none)
                ForEach(AIModelCategory.allCases) { category in
                    Text(category == .llm ? "LLM" : "Decision").tag(Optional(category))
                }
            }
            Picker("Family", selection: $filters.family) {
                Text("All").tag(String?.none)
                ForEach(Array(Set(catalog.map(\.family))).sorted(), id: \.self) { family in
                    Text(family).tag(Optional(family))
                }
            }
            LocalModelScorePicker(selection: $filters.score, catalog: catalog)
            Toggle("Runnable on This Mac", isOn: $filters.runnableOnly)
                .help("Matches recommended RAM and Metal requirements")
        }
        .pickerStyle(.menu)
        .padding()
        .accessibilityLabel("Filter downloadable models")
    }

    private var statusTitle: String {
        switch state {
        case .available: "Available"
        case .checking: "Checking…"
        case .downloading: "Downloading…"
        case .installed: "Installed"
        case .failed: "Failed"
        }
    }
}
