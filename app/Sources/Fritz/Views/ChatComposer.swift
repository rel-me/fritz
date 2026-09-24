import FritzUI
import Fritz
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
    let initialSearchText: String

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
        self.initialSearchText = initialSearchText
    }

    var body: some View {
        FritzUI.ModelPickerPopover(
            models: models.map(Self.item), recentModels: recentModels.map(Self.item),
            modelProviders: (modelProviders + AIProviderKind.allCases).map(\.rawValue),
            selectedModelID: selectedModelID,
            selectModel: { selectModel($0.value) }, configureModels: configureModels,
            recommendationLimit: 8, initialSearchText: initialSearchText
        )
        .fritzPickerStyle(PickerStyle(background: ChatVisualStyle.composerBackground))
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
