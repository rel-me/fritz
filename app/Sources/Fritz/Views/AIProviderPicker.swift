import Fritz
import SwiftUI

struct AIProviderPicker: View {
    @Binding var selection: AIProviderPreset
    var providers: [AIProviderPreset] = AIProviderPreset.allCases
    @State private var isPresented = false

    var body: some View {
        LabeledContent("Provider") {
            Button {
                isPresented = true
            } label: {
                HStack {
                    Text(selection.name)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                }
            }
            .accessibilityLabel("Provider")
            .accessibilityValue(selection.name)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                AIProviderPickerContent(selection: selection, providers: providers) { provider in
                    selection = provider
                    isPresented = false
                }
            }
        }
    }
}

struct AIProviderPickerContent: View {
    let selection: AIProviderPreset
    let providers: [AIProviderPreset]
    let onSelect: (AIProviderPreset) -> Void
    @State private var searchText: String
    @FocusState private var isSearchFocused: Bool
    @State private var hoveredProvider: AIProviderPreset?
    @State private var selectedCategory: AIProviderCategory = .all
    @State private var hoveredCategory: AIProviderCategory?

    init(
        selection: AIProviderPreset,
        initialSearchText: String = "",
        initialCategory: AIProviderCategory = .all,
        providers: [AIProviderPreset] = AIProviderPreset.allCases,
        onSelect: @escaping (AIProviderPreset) -> Void
    ) {
        self.selection = selection
        self.providers = providers
        self.onSelect = onSelect
        _searchText = State(initialValue: initialSearchText)
        _selectedCategory = State(initialValue: initialCategory)
    }

    private var filteredProviders: [AIProviderPreset] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return providers.filter { provider in
            selectedCategory.contains(provider)
                && (query.isEmpty || provider.name.localizedStandardContains(query)
                    || AIProviderCategory.allCases.contains {
                        $0 != .all && $0.contains(provider) && $0.rawValue.localizedStandardContains(query)
                    })
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search providers", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onSubmit {
                        if let provider = filteredProviders.first {
                            onSelect(provider)
                        }
                    }
                Button("Clear search", systemImage: "xmark.circle.fill") {
                    searchText = ""
                    isSearchFocused = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(FritzButtonStyle(.inline))
                .foregroundStyle(.secondary)
                .opacity(searchText.isEmpty ? 0 : 1)
                .disabled(searchText.isEmpty)
                .accessibilityHidden(searchText.isEmpty)
            }
            .padding(12)

            categoryFilters
            Divider()

            if filteredProviders.isEmpty {
                Text("No matching providers")
                    .foregroundStyle(.secondary)
                    .padding(24)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(filteredProviders) { provider in
                            Button {
                                onSelect(provider)
                            } label: {
                                HStack {
                                    Text(provider.name)
                                    if AIProviderCategory.local.contains(provider) {
                                        Text("local")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.quaternary, in: Capsule())
                                    }
                                    Spacer()
                                    Image(systemName: "checkmark")
                                        .opacity(provider == selection ? 1 : 0)
                                        .accessibilityHidden(true)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    hoveredProvider == provider ? Color.primary.opacity(0.08) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(FritzButtonStyle(.inline))
                            .onHover { hoveredProvider = $0 ? provider : nil }
                            .accessibilityAddTraits(provider == selection ? .isSelected : [])
                        }
                    }
                    .padding(6)
                }
            }
        }
        .frame(width: 440, height: 420, alignment: .top)
        .multilineTextAlignment(.leading)
        .onAppear { isSearchFocused = true }
    }

    private var categoryFilters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(AIProviderCategory.allCases) { category in
                    let isSelected = selectedCategory == category
                    Button {
                        selectedCategory = isSelected ? .all : category
                    } label: {
                        Text(category.rawValue)
                            .font(.callout)
                            .foregroundStyle(isSelected ? .primary : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                isSelected ? ChatVisualStyle.modelPickerSelectionFill
                                    : hoveredCategory == category ? ChatVisualStyle.subtleFill
                                    : ChatVisualStyle.quieterFill,
                                in: Capsule()
                            )
                            .overlay {
                                Capsule().stroke(isSelected ? ChatVisualStyle.hairline : Color.clear)
                            }
                    }
                    .buttonStyle(FritzButtonStyle(.inline))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("provider-category-\(category.rawValue.lowercased())")
                    .help(category.help)
                    .onHover { hoveredCategory = $0 ? category : nil }
                }
            }
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 10)
    }

}
