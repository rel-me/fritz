import FritzUI
import Fritz
// Adapted from REL’s native composer and model picker.
import SwiftUI

struct ChatComposer: View {
    @Binding var draft: String
    let placeholder: String
    let canSend: Bool
    let isResponding: Bool
    let isFocused: FocusState<Bool>.Binding
    let models: [ChatModelOption]
    let recentModels: [ChatModelOption]
    let modelProviders: [AIProviderKind]
    let configuredProviderIDs: Set<String>
    let hasConfiguredModels: Bool
    let isLoadingModels: Bool
    let selectedModel: ChatModelOption?
    let selectedEffort: ChatReasoningEffort
    let selectedSpeed: ChatSpeed
    let selectModel: (ChatModelOption) -> Void
    let selectEffort: (ChatReasoningEffort) -> Void
    let selectSpeed: (ChatSpeed) -> Void
    let configureModels: () -> Void
    let addProvider: (AIProviderPreset?) -> Void
    let send: () -> Void
    let stop: () -> Void

    var body: some View {
        FritzUI.ChatComposer(
            draft: $draft, placeholder: placeholder, canSend: canSend,
            isResponding: isResponding, isFocused: isFocused,
            background: FritzWindowStyle.chatInputBackground,
            cornerRadius: ChatVisualStyle.composerCornerRadius,
            send: send, stop: stop
        ) {
            ChatModelPicker(
                models: models,
                recentModels: recentModels,
                modelProviders: modelProviders,
                configuredProviderIDs: configuredProviderIDs,
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
        }
    }
}

private struct ChatModelPicker: View {
    let models: [ChatModelOption]
    let recentModels: [ChatModelOption]
    let modelProviders: [AIProviderKind]
    let configuredProviderIDs: Set<String>
    let hasConfiguredModels: Bool
    let isLoadingModels: Bool
    let selectedModel: ChatModelOption?
    let selectedEffort: ChatReasoningEffort
    let selectedSpeed: ChatSpeed
    let selectModel: (ChatModelOption) -> Void
    let selectEffort: (ChatReasoningEffort) -> Void
    let selectSpeed: (ChatSpeed) -> Void
    let configureModels: () -> Void
    let addProvider: (AIProviderPreset?) -> Void
    @State private var isChoosingModel = false

    var body: some View {
        if hasConfiguredModels {
            Button {
                isChoosingModel = true
            } label: {
                FritzUI.ModelPickerLabel(
                    title: selectedModel?.displayName ?? "Choose Model",
                    details: (selectedModel?.capabilities.supportsReasoningEffort == true
                        ? [selectedEffort.displayName] : []) + (speedTitle.map { [$0] } ?? [])
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Model, thinking, and speed")
            .accessibilityValue(configurationSummary)
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
            FritzUI.ChatProviderSetupButton(action: { addProvider(nil) })
        }
    }

    private var speedTitle: String? {
        guard selectedModel?.capabilities.supportsSpeed == true,
              selectedSpeed != .standard else { return nil }
        return selectedSpeed == .priority ? "Fast" : selectedSpeed.displayName
    }

    private var configurationSummary: String {
        guard let selectedModel else { return "Choose Model" }
        var values = [selectedModel.displayName]
        if selectedModel.capabilities.supportsReasoningEffort {
            values.append(selectedEffort.displayName)
        }
        if let speedTitle { values.append(speedTitle) }
        return values.joined(separator: ", ")
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
                configuredProviderIDs: configuredProviderIDs,
                addProvider: { preset in isChoosingModel = false; addProvider(preset) },
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
        .background(Color(nsColor: .textBackgroundColor))
    }

}

struct ChatModelPickerPopover: View {
    let models: [ChatModelOption]
    let recentModels: [ChatModelOption]
    let modelProviders: [AIProviderKind]
    let configuredProviderIDs: Set<String>
    let addProvider: (AIProviderPreset?) -> Void
    let selectedModelID: String?
    let selectModel: (ChatModelOption) -> Void
    let configureModels: () -> Void
    let initialSearchText: String

    init(
        models: [ChatModelOption],
        recentModels: [ChatModelOption],
        modelProviders: [AIProviderKind],
        configuredProviderIDs: Set<String>,
        addProvider: @escaping (AIProviderPreset?) -> Void,
        selectedModelID: String?,
        selectModel: @escaping (ChatModelOption) -> Void,
        configureModels: @escaping () -> Void,
        initialSearchText: String = ""
    ) {
        self.models = models
        self.recentModels = recentModels
        self.configuredProviderIDs = configuredProviderIDs
        self.addProvider = addProvider
        self.modelProviders = modelProviders
        self.selectedModelID = selectedModelID
        self.selectModel = selectModel
        self.configureModels = configureModels
        self.initialSearchText = initialSearchText
    }

    var body: some View {
        FritzUI.ModelPickerPopover(
            models: chatModels.map(Self.item), recentModels: recentModels.map(Self.item),
            modelProviders: (modelProviders + AIProviderKind.allCases).map(\.rawValue),
            selectedModelID: selectedModelID,
            selectModel: { selectModel($0.value) }, configureModels: configureModels,
            recommendationLimit: 8, initialSearchText: initialSearchText,
            supportedProviders: PickerProvider.chatProviders,
            configuredProviderIDs: configuredProviderIDs,
            addProvider: { provider in
                if let preset = AIProviderPreset.allCases.first(where: { $0.id == provider.id }) {
                    addProvider(preset)
                }
            }
        )
        .fritzPickerStyle(PickerStyle(background: Color(nsColor: .textBackgroundColor)))
    }

    private var chatModels: [ChatModelOption] {
        models.filter { $0.provider != .openAI || $0.capabilities.isRecommendedInChatPicker }
    }

    static func item(_ model: ChatModelOption) -> ModelPickerItem<ChatModelOption> {
        .init(id: model.id, value: model, displayName: model.displayName, modelID: model.modelID,
              provider: .init(id: model.displayProvider.id, displayName: model.displayProvider.displayName,
                              groupID: model.provider.rawValue),
              sourceName: model.connectionName, isRecommended: model.capabilities.isRecommendedInChatPicker,
              badge: model.verification == .compatible ? .init(
                systemImage: "wrench.and.screwdriver",
                help: "Provider reports tool compatibility; not yet Fritz verified",
                accessibilityLabel: "Tool compatible, not Fritz verified"
              ) : nil)
    }
}
