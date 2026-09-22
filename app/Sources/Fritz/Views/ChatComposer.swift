// Adapted from REL’s native composer and model picker.
import SwiftUI

struct ChatComposer: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var draft: String
    let placeholder: String
    let canSend: Bool
    let isResponding: Bool
    let isFocused: FocusState<Bool>.Binding
    let models: [ChatModelOption]
    let recentModels: [ChatModelOption]
    let modelProviders: [AIProviderKind]
    let hasConfiguredModels: Bool
    let isLoadingModels: Bool
    let selectedModel: ChatModelOption?
    let selectedEffort: ChatReasoningEffort
    let selectedSpeed: ChatSpeed
    let selectModel: (ChatModelOption) -> Void
    let selectEffort: (ChatReasoningEffort) -> Void
    let selectSpeed: (ChatSpeed) -> Void
    let configureModels: () -> Void
    let addProvider: () -> Void
    let resetChat: () -> Void
    let send: () -> Void
    let stop: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TextField(
                placeholder,
                text: $draft,
                prompt: Text(placeholder)
                    .foregroundStyle(ChatVisualStyle.composerSecondaryForeground),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.body)
            .accessibilityLabel("Message")
            .lineLimit(1...20)
            .fixedSize(horizontal: false, vertical: true)
            .focused(isFocused)
            .onSubmit { if canSend && !isResponding { send() } }
            .frame(minHeight: 44, alignment: .topLeading)
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 6)

            HStack(spacing: 6) {
                Menu("Chat Options", systemImage: "ellipsis.circle") {
                    Button("Reset Chat", systemImage: "arrow.counterclockwise", action: resetChat)

                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .modifier(FritzPanelIconControl())
                .accessibilityIdentifier("chat-options")
                .help("Chat Options")

                Spacer(minLength: 6)

                ChatModelPicker(
                    models: models,
                    recentModels: recentModels,
                    modelProviders: modelProviders,
                    hasConfiguredModels: hasConfiguredModels,
                    isLoadingModels: isLoadingModels,
                    selectedModel: selectedModel,
                    selectedEffort: selectedEffort,
                    selectedSpeed: selectedSpeed,
                    selectModel: selectModel,
                    selectEffort: selectEffort,
                    selectSpeed: selectSpeed,
                    configureModels: configureModels,
                    addProvider: addProvider
                )
                .disabled(isResponding)

                Button(action: performPrimaryAction) {
                    Image(systemName: isResponding ? "stop.fill" : "arrow.up")
                        .font(isResponding ? .callout.weight(.bold) : .system(size: 15, weight: .regular))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(FritzButtonStyle(.floatingPrimary, size: .regular, shape: .circle))
                .accessibilityLabel(isResponding ? "Stop" : "Send")
                .disabled(!isResponding && !canSend)
                .keyboardShortcut(isResponding ? .cancelAction : .defaultAction)
                .help(isResponding ? "Stop Agent" : "Send Message")
            }
            .modifier(FritzGlassControlGroup())
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 10)
            .padding(.trailing, 9)
            .padding(.bottom, 9)
        }
        .background {
            Button(action: focusMessageField) {
                RoundedRectangle(
                    cornerRadius: ChatVisualStyle.composerCornerRadius,
                    style: .continuous
                )
                .fill(ChatVisualStyle.composerBackground)
            }
            .buttonStyle(FritzButtonStyle(.inline))
            .accessibilityHidden(true)
        }
        .modifier(FritzInputSurfaceBorder(
            cornerRadius: ChatVisualStyle.composerCornerRadius,
            isFocused: isFocused.wrappedValue
        ))
        .shadow(
            color: ChatVisualStyle.composerShadow(for: colorScheme),
            radius: ChatVisualStyle.composerShadowRadius,
            y: ChatVisualStyle.composerShadowY
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private func performPrimaryAction() {
        if isResponding {
            stop()
        } else {
            send()
        }
    }

    private func focusMessageField() {
        isFocused.wrappedValue = true
    }
}

private struct ChatModelPicker: View {
    let models: [ChatModelOption]
    let recentModels: [ChatModelOption]
    let modelProviders: [AIProviderKind]
    let hasConfiguredModels: Bool
    let isLoadingModels: Bool
    let selectedModel: ChatModelOption?
    let selectedEffort: ChatReasoningEffort
    let selectedSpeed: ChatSpeed
    let selectModel: (ChatModelOption) -> Void
    let selectEffort: (ChatReasoningEffort) -> Void
    let selectSpeed: (ChatSpeed) -> Void
    let configureModels: () -> Void
    let addProvider: () -> Void
    @State private var isChoosingModel = false

    var body: some View {
        if hasConfiguredModels {
            Button {
                isChoosingModel = true
            } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        Text(selectedModel?.displayName ?? "Choose Model")
                        configurationTitle
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                    .accessibilityIdentifier("chat-configuration-expanded")

                    HStack(spacing: 4) {
                        Text(selectedModel?.displayName ?? "Choose Model")
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .frame(minWidth: 100)
                    .accessibilityIdentifier("chat-configuration-compact")
                }
                .font(.body)
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(FritzButtonStyle(.inline))
            .accessibilityLabel("Model, thinking, and speed")
            .accessibilityValue(
                selectedModel.map { "\($0.displayName), \(selectedEffort.displayName), \(selectedSpeed.displayName)" }
                        ?? "Choose Model"
            )
            .help("Choose Model, Thinking, and Speed")
            .popover(isPresented: $isChoosingModel, arrowEdge: .bottom) {
                configurationPopover
            }
        } else if isLoadingModels {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading Models…")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        } else {
            providerSetupButton
                .buttonStyle(FritzButtonStyle())
        }
    }

    private var providerSetupButton: some View {
        Button("Add Provider", action: addProvider)
            .font(.body)
            .controlSize(.regular)
            .help("Add Provider")
    }

    private var configurationTitle: Text {
        let thinking = selectedModel?.capabilities.supportsReasoningEffort == true
            ? selectedEffort.displayName : ""
        if selectedModel?.capabilities.supportsSpeed == true, selectedSpeed != .standard {
            return Text("\(thinking) \(Image(systemName: "bolt.fill"))")
        }
        return Text(thinking)
    }

    @ViewBuilder
    private var speedOptions: some View {
        if let selectedModel, selectedModel.capabilities.supportsSpeed {
            Picker("Speed", selection: Binding(
                get: { selectedSpeed },
                set: { selectSpeed($0) }
            )) {
                ForEach(selectedModel.capabilities.supportedSpeeds) { speed in
                    Text(speed == .priority ? "Fast" : speed.displayName).tag(speed)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    private var configurationPopover: some View {
        VStack(spacing: 0) {
            ChatModelPickerPopover(
                models: models,
                recentModels: recentModels,
                modelProviders: modelProviders,
                selectedModelID: selectedModel?.id,
                selectModel: selectModel,
                configureModels: {
                    isChoosingModel = false
                    configureModels()
                }
            )

            if selectedModel?.capabilities.supportsReasoningEffort == true
                || selectedModel?.capabilities.supportsSpeed == true {
                Divider()

                HStack(spacing: 12) {
                    if selectedModel?.capabilities.supportsReasoningEffort == true {
                        Picker("Thinking", selection: Binding(
                            get: { selectedEffort },
                            set: { selectEffort($0) }
                        )) {
                            ForEach(selectedModel?.capabilities.reasoningEfforts ?? []) { effort in
                                Text(effort.displayName).tag(effort)
                            }
                        }
                        .fixedSize()
                    }

                    Spacer(minLength: 0)
                    speedOptions
                }
                .padding(12)
            }
        }
        .frame(width: 440)
        .background(ChatVisualStyle.composerBackground)
    }

}

struct ChatModelPickerPopover: View {
    let models: [ChatModelOption]
    let recentModels: [ChatModelOption]
    let modelProviders: [AIProviderKind]
    let selectedModelID: String?
    let selectModel: (ChatModelOption) -> Void
    let configureModels: () -> Void
    @State private var searchText = ""
    @State private var selectedProvider: AIProviderPreset?
    @State private var hoveredProviderFilterID: String?
    @FocusState private var isSearchFocused: Bool

    init(
        models: [ChatModelOption],
        recentModels: [ChatModelOption],
        modelProviders: [AIProviderKind],
        selectedModelID: String?,
        selectModel: @escaping (ChatModelOption) -> Void,
        configureModels: @escaping () -> Void,
        initialSearchText: String = ""
    ) {
        self.models = models
        self.recentModels = recentModels
        self.modelProviders = modelProviders
        self.selectedModelID = selectedModelID
        self.selectModel = selectModel
        self.configureModels = configureModels
        _searchText = State(initialValue: initialSearchText)
    }

    var body: some View {
        let showsUnfilteredSections = query.isEmpty && selectedProvider == nil
        let sections = showsUnfilteredSections ? unfilteredSections : []
        let visibleModels = showsUnfilteredSections
            ? sections.flatMap(\.models)
            : filteredModels
        let showsSourceName = Set(
            visibleModels.map { $0.displayProvider.displayName }
        ).count > 1

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search models", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($isSearchFocused)
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
            .fixedSize(horizontal: false, vertical: true)

            ModelProviderFlowLayout(spacing: 6) {
                ForEach(ChatModelPickerSection.displayProviders(from: models, providerOrder: modelProviders)) { provider in
                    let filterID = provider.id
                    let isSelected = selectedProvider == provider
                    let isHovered = hoveredProviderFilterID == filterID

                    Button {
                        selectedProvider = isSelected ? nil : provider
                    } label: {
                        Text(provider.displayName)
                            .font(.callout)
                            .foregroundStyle(isSelected ? .primary : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                isSelected
                                    ? ChatVisualStyle.modelPickerSelectionFill
                                    : isHovered
                                        ? ChatVisualStyle.subtleFill
                                        : ChatVisualStyle.quieterFill,
                                in: Capsule()
                            )
                            .overlay {
                                Capsule()
                                    .stroke(
                                        isSelected ? ChatVisualStyle.hairline : Color.clear
                                    )
                            }
                    }
                    .buttonStyle(FritzButtonStyle(.inline))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("chat-model-provider-filter-\(filterID)")
                    .help(
                        isSelected
                            ? "Show models from all providers"
                            : "Show only \(provider.displayName) models"
                    )
                    .onHover { hovering in
                        if hovering {
                            hoveredProviderFilterID = filterID
                        } else if hoveredProviderFilterID == filterID {
                            hoveredProviderFilterID = nil
                        }
                    }
                }

                Button("Open Models", action: configureModels)
                    .font(.callout)
                    .buttonStyle(FritzButtonStyle(.primary))
                    .buttonBorderShape(.capsule)
                    .fritzButtonSize(.small)
                    .help("Open Model Providers")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if showsUnfilteredSections {
                        ForEach(sections) { section in
                            let sectionShowsSourceName = Set(
                                section.models.map { $0.displayProvider.displayName }
                            ).count > 1

                            // Keep repeated recent/provider models in separate identity scopes.
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                                    .accessibilityAddTraits(.isHeader)

                                ForEach(section.models) { model in
                                    ChatModelPickerListRow(
                                        model: model,
                                        selectedModelID: selectedModelID,
                                        showsSourceName: sectionShowsSourceName,
                                        selectModel: selectModel
                                    )
                                }
                            }
                        }
                    } else {
                        ForEach(visibleModels) { model in
                            ChatModelPickerListRow(
                                model: model,
                                selectedModelID: selectedModelID,
                                showsSourceName: showsSourceName,
                                selectModel: selectModel
                            )
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 4)
            .overlay {
                if visibleModels.isEmpty {
                    Text("No results")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 440, height: 380)
        .background(ChatVisualStyle.composerBackground)
        .onAppear {
            isSearchFocused = true
        }
    }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var unfilteredSections: [ChatModelPickerSection] {
        ChatModelPickerSection.unfiltered(
            from: models,
            recentModels: recentModels,
            providerOrder: modelProviders
        )
    }

    private var filteredModels: [ChatModelOption] {
        let providerModels: [ChatModelOption]
        if let selectedProvider {
            providerModels = models.filter { $0.displayProvider == selectedProvider }
        } else {
            providerModels = models
        }

        guard !query.isEmpty else {
            return ChatModelOption.balancedPickerRecommendations(
                from: providerModels,
                providerOrder: selectedProvider.map { [$0.provider] } ?? modelProviders,
                selectedModelID: selectedModelID,
                limit: 8
            )
        }
        return providerModels.filter { model in
            model.displayName.localizedStandardContains(query)
                || model.modelID.localizedStandardContains(query)
                || model.displayProvider.displayName.localizedStandardContains(query)
                || model.connectionName?.localizedStandardContains(query) == true
        }
    }
}

private struct ModelProviderFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(width: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, layout.origins) {
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                anchor: .topLeading,
                proposal: .unspecified
            )
        }
    }

    private func arrangement(width: CGFloat?, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        let availableWidth = width ?? .infinity
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > availableWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            contentWidth = max(contentWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: availableWidth.isFinite ? availableWidth : contentWidth, height: y + rowHeight), origins)
    }
}

private struct ChatModelPickerListRow: View {
    @Environment(\.dismiss) private var dismiss
    let model: ChatModelOption
    let selectedModelID: String?
    let showsSourceName: Bool
    let selectModel: (ChatModelOption) -> Void

    var body: some View {
        Button(action: select) {
            ChatModelPickerRow(
                model: model,
                isSelected: model.id == selectedModelID,
                showsSourceName: showsSourceName
            )
        }
        .buttonStyle(FritzButtonStyle(.inline))
        .accessibilityAddTraits(model.id == selectedModelID ? .isSelected : [])
    }

    private func select() {
        selectModel(model)
        dismiss()
    }
}

private struct ChatModelPickerRow: View {
    let model: ChatModelOption
    let isSelected: Bool
    let showsSourceName: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Text(model.displayName)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            if model.verification == .compatible {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(.secondary)
                    .help("Provider reports tool compatibility; not yet Fritz verified")
                    .accessibilityLabel("Tool compatible, not Fritz verified")
            }

            if showsSourceName {
                Text(model.displayProvider.displayName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .opacity(isSelected ? 1 : 0)
                .accessibilityHidden(true)
        }
        .font(.body)
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected
                ? ChatVisualStyle.modelPickerSelectionFill
                : isHovered ? ChatVisualStyle.subtleFill : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
