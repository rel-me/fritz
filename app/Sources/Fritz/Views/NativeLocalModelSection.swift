import Fritz
import FritzUI
import SwiftUI

typealias NativeModelInstallState = LocalModelInstallState

struct NativeModelFilters: Equatable {
    var category: AIModelCategory?
    var family: String?

    func models(in catalog: [NativeModelDescriptor]) -> [NativeModelDescriptor] {
        catalog.filter {
            (category == nil || $0.category == category) && (family == nil || $0.family == family)
        }
    }
}

struct NativeLocalModelSection: View {
    private let filterStyle = PickerStyle()
    @State private var hoveredFilter: String?
    @Binding var filters: NativeModelFilters
    @Binding var modelID: String
    let state: NativeModelInstallState
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
            filterCapsules
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
            .fritzListSurface()
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

            if filteredModels.contains(where: { $0.id == modelID }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(model.name) · \(hardware.summary)")
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

    private var filterCapsules: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                filterCapsule("All", id: "all", selected: filters == NativeModelFilters()) {
                    filters = NativeModelFilters()
                }
                ForEach(AIModelCategory.allCases) { category in
                    filterCapsule(category == .llm ? "LLM" : "Decision", id: category.rawValue,
                                  selected: filters.category == category) {
                        filters.category = filters.category == category ? nil : category
                    }
                }
                Divider().frame(height: 18).padding(.horizontal, 4)
                ForEach(Array(Set(catalog.map(\.family))).sorted(), id: \.self) { family in
                    filterCapsule(family, id: family, selected: filters.family == family) {
                        filters.family = filters.family == family ? nil : family
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(state.isBusy)
        .accessibilityLabel("Filter downloadable models")
    }

    private func filterCapsule(_ title: String, id: String, selected: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(selected ? filterStyle.selectionFill
                            : hoveredFilter == id ? filterStyle.hoverFill : filterStyle.quietFill, in: Capsule())
                .overlay { Capsule().stroke(selected ? filterStyle.border : .clear) }
                .contentShape(Capsule())
        }
        .buttonStyle(FritzButtonStyle(.inline))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("download-model-filter-\(id)")
        .help(id == "all" ? "Show all models" : selected ? "Remove the \(title) filter" : "Filter by \(title)")
        .onHover { hoveredFilter = $0 ? id : nil }
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
