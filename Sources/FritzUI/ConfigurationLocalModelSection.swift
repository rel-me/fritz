import Fritz
import SwiftUI


struct NativeModelFilters: Equatable {
    var category: AIModelCategory?
    var family: String?

    func models(in catalog: [NativeModelDescriptor]) -> [NativeModelDescriptor] {
        catalog.filter {
            (category == nil || $0.category == category) && (family == nil || $0.family == family)
        }
    }
}

struct ConfigurationLocalModelSection: View {
    @Binding var filters: NativeModelFilters
    @Binding var modelID: String
    let state: LocalModelInstallState
    let hardware: LocalModelHardware
    let catalog: [NativeModelDescriptor]

    private var filteredModels: [NativeModelDescriptor] { filters.models(in: catalog) }

    private var model: NativeModelDescriptor {
        catalog.first { $0.id == modelID }!
    }

    private var selection: Binding<String?> {
        Binding(
            get: { modelID },
            set: { if let id = $0, !state.isBusy { modelID = id } }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            nativeFilters
            Divider()
            Table(filteredModels, selection: selection) {
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
                        if entry.id == modelID {
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
                .width(min: 210, ideal: 230)
            }
            .disabled(state.isBusy)
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
               state != .available || hardware.memoryGB < model.memoryGB || !hardware.appleSilicon {
                VStack(alignment: .leading, spacing: 6) {
                    if hardware.memoryGB < model.memoryGB {
                        Text("This Mac has \(hardware.memoryGB) GB memory. A smaller model is recommended.")
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
                    case let .downloading(downloaded, total):
                        ProgressView(value: Double(downloaded), total: Double(total))
                            .accessibilityLabel("Downloading local model")
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(downloaded), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))")
                            .monospacedDigit()
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
        }
        .pickerStyle(.menu)
        .padding()
        .disabled(state.isBusy)
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
