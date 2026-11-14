import FritzUI
import Fritz
// Adapted from REL’s native composer and model picker.
import SwiftUI

struct ChatComposer: View {
    @Binding var draft: String
    let placeholder: String
    let canSend: Bool
    let isPreparingModel: Bool
    let isResponding: Bool
    let isFocused: FocusState<Bool>.Binding
    let models: [ChatModelOption]
    let recentModels: [ChatModelOption]
    let modelProviders: [AIProviderKind]
    let selectedModel: ChatModelOption?
    let selectedEffort: ChatReasoningEffort
    let selectedSpeed: ChatSpeed
    let selectModel: (ChatModelOption) -> Void
    let selectEffort: (ChatReasoningEffort) -> Void
    let selectSpeed: (ChatSpeed) -> Void
    let configureModels: () -> Void
    let configureLocalModels: () -> Void
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
            HStack(spacing: 6) {
                if isPreparingModel { ProgressView().controlSize(.small).accessibilityLabel("Setting up model") }
            ChatModelPicker(
                models: models,
                recentModels: recentModels,
                modelProviders: modelProviders,
                selectedModel: selectedModel,
                selectedEffort: selectedEffort,
                selectedSpeed: selectedSpeed,
                selectModel: selectModel,
                selectEffort: selectEffort,
                selectSpeed: selectSpeed,
                configureModels: configureModels,
                configureLocalModels: configureLocalModels
            )
            .disabled(isResponding || isPreparingModel)
            }
        }
    }
}

private struct ChatModelPicker: View {
    let models: [ChatModelOption]
    let recentModels: [ChatModelOption]
    let modelProviders: [AIProviderKind]
    let selectedModel: ChatModelOption?
    let selectedEffort: ChatReasoningEffort
    let selectedSpeed: ChatSpeed
    let selectModel: (ChatModelOption) -> Void
    let selectEffort: (ChatReasoningEffort) -> Void
    let selectSpeed: (ChatSpeed) -> Void
    let configureModels: () -> Void
    let configureLocalModels: () -> Void
    @State private var isChoosingModel = false

    var body: some View {
        Button {
            isChoosingModel = true
        } label: {
            FritzUI.ModelPickerLabel(
                title: selectedModel?.displayName ?? "Choose Model…",
                details: (selectedModel?.capabilities.supportsReasoningEffort == true
                    ? [selectedEffort.displayName] : []) + (speedTitle.map { [$0] } ?? [])
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose Model…")
        .accessibilityValue(configurationSummary)
        .help("Choose Model…")
        .popover(isPresented: $isChoosingModel, arrowEdge: .bottom) { configurationPopover }
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
                selectedModelID: selectedModel?.id,
                selectModel: { model in isChoosingModel = false; selectModel(model) },
                configureModels: {
                    isChoosingModel = false
                    configureModels()
                }, configureLocalModels: {
                    isChoosingModel = false
                    configureLocalModels()
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
    let selectedModelID: String?
    let selectModel: (ChatModelOption) -> Void
    let configureModels: () -> Void
    let configureLocalModels: () -> Void
    let initialSearchText: String

    init(
        models: [ChatModelOption],
        recentModels: [ChatModelOption],
        modelProviders: [AIProviderKind],
        selectedModelID: String?,
        selectModel: @escaping (ChatModelOption) -> Void,
        configureModels: @escaping () -> Void,
        configureLocalModels: @escaping () -> Void,
        initialSearchText: String = ""
    ) {
        self.models = models
        self.recentModels = recentModels
        self.modelProviders = modelProviders
        self.selectedModelID = selectedModelID
        self.selectModel = selectModel
        self.configureModels = configureModels
        self.configureLocalModels = configureLocalModels
        self.initialSearchText = initialSearchText
    }

    var body: some View {
        FritzUI.ModelPickerPopover(
            models: chatModels.map(Self.item), recentModels: recentModels.map(Self.item),
            modelProviders: (modelProviders + AIProviderKind.allCases).map(\.rawValue),
            selectedModelID: selectedModelID,
            selectModel: { selectModel($0.value) }, configureModels: configureModels,
            initialSearchText: initialSearchText,
            supportedProviders: PickerProvider.chatProviders,
            configureLocalModels: configureLocalModels
        )
        .fritzPickerStyle(PickerStyle(background: Color(nsColor: .textBackgroundColor)))
    }

    private var chatModels: [ChatModelOption] {
        models.filter { $0.category == .llm }
    }

    static func item(_ model: ChatModelOption) -> ModelPickerItem<ChatModelOption> {
        .init(id: model.id, value: model, displayName: model.displayName, modelID: model.modelID,
              provider: .init(id: model.displayProvider.id, displayName: model.displayProvider.displayName,
                              groupID: model.provider.rawValue),
              sourceName: model.connectionName, isRecommended: model.capabilities.isRecommendedInChatPicker,
              badge: model.connectionID == nil ? .init(systemImage: "plus.circle", help: "Set up model",
                accessibilityLabel: "Setup required") : model.verification == .compatible ? .init(
                systemImage: "wrench.and.screwdriver",
                help: "Provider reports tool compatibility; not yet Fritz verified",
                accessibilityLabel: "Tool compatible, not Fritz verified"
              ) : nil)
    }
}
