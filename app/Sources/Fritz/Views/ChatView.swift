import SwiftUI

struct ChatView: View {
    @Bindable var store: ChatStore
    let providers: ProviderStore
    let openProviders: () -> Void
    let addProvider: () -> Void
    @FocusState private var isFocused: Bool
    @State private var confirmsReset = false

    var body: some View {
        VStack(spacing: 0) {
            if store.messages.isEmpty {
                VStack(spacing: 14) {
                    Image("FritzMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 54, height: 66)
                        .accessibilityHidden(true)
                    Text("What are we working on?")
                        .font(.system(size: 26, weight: .medium))
                    Text(providers.connections.isEmpty
                         ? "Add a provider to start a conversation with Fritz."
                         : "Ask a question, explore an idea, or work through some code.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcript
            }

            VStack(spacing: 10) {
                if let error = store.error ?? store.agent.startupError {
                    HStack(alignment: .top) {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange).textSelection(.enabled)
                        Spacer()
                        if !store.agent.isRunning {
                            Button("Restart") { store.agent.restart(); Task { await providers.refresh() } }
                        } else {
                            Button("Dismiss", systemImage: "xmark") { store.error = nil }.labelStyle(.iconOnly)
                        }
                    }
                    .font(.callout)
                }
                if let tokens = store.responseTokens {
                    Text("\(tokens.formatted()) tokens reported")
                        .font(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if store.projectPath != nil {
                    HStack(spacing: 12) {
                        Text("Code")
                            .font(.callout.weight(.medium))
                        Text("Can edit files and run commands")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
                ChatComposer(
                    draft: $store.draft,
                    placeholder: store.messages.isEmpty ? "Ask Fritz anything" : "Ask for follow-up changes",
                    canSend: store.canSend,
                    isResponding: store.isResponding,
                    isFocused: $isFocused,
                    models: providers.models,
                    recentModels: providers.recentModels,
                    modelProviders: providers.providerOrder,
                    hasConfiguredModels: !providers.connections.isEmpty,
                    isLoadingModels: providers.isLoading,
                    selectedModel: store.selectedModel,
                    selectedEffort: store.effort,
                    selectedSpeed: store.speed,
                    selectModel: { store.select($0); providers.record($0) },
                    selectEffort: { store.effort = $0 },
                    selectSpeed: { store.speed = $0 },
                    configureModels: openProviders,
                    addProvider: addProvider,
                    resetChat: { confirmsReset = true },
                    send: { if let model = store.selectedModel { providers.record(model) }; store.send() },
                    stop: store.stop
                )
            }
            .frame(maxWidth: ChatVisualStyle.contentMaxWidth)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(ChatVisualStyle.pageBackground)
        .confirmationDialog("Clear this thread?", isPresented: $confirmsReset) {
            Button("Clear Conversation", role: .destructive) { store.clear(); isFocused = true }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The current conversation will be removed from this Mac.") }
        .onExitCommand(perform: store.stop)
        .onAppear { isFocused = true; synchronizeModel() }
        .onDisappear { store.savePreferences() }
        .onChange(of: providers.models) { _, _ in synchronizeModel() }
        .onChange(of: providers.hasLoadedModels) { _, _ in synchronizeModel() }
        .onChange(of: store.effort) { _, _ in store.savePreferences() }
        .onChange(of: store.speed) { _, _ in store.savePreferences() }
        .onChange(of: store.isResponding) { _, responding in if !responding { synchronizeModel() } }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ChatVisualStyle.transcriptSpacing) {
                    ForEach(store.messages) { message in
                        let isActive = store.isResponding && message.id == store.messages.last?.id
                        VStack(alignment: .leading, spacing: 8) {
                            if message.role == "user" {
                                Text(message.content)
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 16).padding(.vertical, 12)
                                    .background(ChatVisualStyle.subtleFill, in: RoundedRectangle(cornerRadius: 16))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            } else {
                                if let tools = message.tools, !tools.isEmpty {
                                    DisclosureGroup("\(tools.count) tool action\(tools.count == 1 ? "" : "s")") {
                                        ForEach(tools) { tool in
                                            DisclosureGroup {
                                                Text(tool.arguments).font(.caption.monospaced()).textSelection(.enabled)
                                                if let result = tool.result {
                                                    Text(result).font(.caption.monospaced()).textSelection(.enabled)
                                                }
                                            } label: {
                                                Label(tool.summary, systemImage: tool.success == true ? "checkmark.circle" : tool.success == false ? "exclamationmark.circle" : isActive ? "ellipsis.circle" : "stop.circle")
                                                    .font(.callout).lineLimit(2)
                                            }
                                        }
                                    }
                                    .padding(12)
                                    .background(ChatVisualStyle.subtleFill, in: RoundedRectangle(cornerRadius: 10))
                                }
                                if !message.content.isEmpty { ChatAssistantMessage(content: message.content) }
                                if !message.isComplete && !isActive {
                                    Text("Response interrupted").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .id(message.id)
                    }
                    if store.isResponding {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(store.activity ?? "Fritz is working…").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: ChatVisualStyle.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: store.activity) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: store.messages.last?.content) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func synchronizeModel() {
        guard providers.hasLoadedModels, !store.isResponding else { return }
        if let selected = store.selectedModel, providers.models.contains(where: { $0.id == selected.id }) { return }
        store.selectedModel = providers.defaultModel
    }
}

struct FritzInputSurfaceBorder: ViewModifier {
    let cornerRadius: CGFloat
    let isFocused: Bool
    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(isFocused ? Color.accentColor.opacity(0.5) : ChatVisualStyle.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}
