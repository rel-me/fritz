import FritzUI
import Fritz
import SwiftUI

struct ChatView: View {
    @Bindable var store: ChatStore
    let providers: ProviderStore
    let openProviders: () -> Void
    let addProvider: () -> Void
    @FocusState private var isFocused: Bool
    @State private var confirmsReset = false
    @State private var composerHeight: CGFloat = 0
    @State private var scrollState = ChatScrollState()
    @State private var scrollPosition = ScrollPosition(idType: String.self, edge: .bottom)
    @State private var isScrollingTranscript = false
    private static let transcriptBottomID = "chat-transcript-bottom"

    var body: some View {
        ZStack(alignment: .bottom) {
            transcript

            VStack(alignment: .trailing, spacing: 8) {
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
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
            .padding(.horizontal, 6)
            .padding(.top, 12)
            .padding(.bottom, 6)
        }
        .background(ChatVisualStyle.pageBackground)
        .confirmationDialog("Clear this thread?", isPresented: $confirmsReset) {
            Button("Clear Conversation", role: .destructive) { store.clear(); isFocused = true }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The current conversation will be removed from this Mac.") }
        .onExitCommand(perform: store.stop)
        .defaultFocus($isFocused, true)
        .task {
            // Let the previous thread release its field before focusing this one.
            await Task.yield()
            guard !Task.isCancelled else { return }
            isFocused = true
        }
        .onAppear(perform: synchronizeModel)
        .onDisappear { store.savePreferences() }
        .onChange(of: providers.models) { _, _ in synchronizeModel() }
        .onChange(of: providers.hasLoadedModels) { _, _ in synchronizeModel() }
        .onChange(of: store.effort) { _, _ in store.savePreferences() }
        .onChange(of: store.speed) { _, _ in store.savePreferences() }
        .onChange(of: store.isResponding) { _, responding in if !responding { synchronizeModel() } }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: ChatVisualStyle.transcriptSpacing) {
                ForEach(store.messages) { message in
                    ChatMessageRow(
                        message: message,
                        isActive: store.isResponding && message.id == store.messages.last?.id,
                        activity: store.activity
                    )
                    .id(message.id.uuidString)
                }
                if let error = store.error ?? store.agent.startupError {
                    VStack(alignment: .leading, spacing: 8) {
                        ChatErrorMessage(content: error)
                        if !store.agent.isRunning {
                            Button("Restart") { store.agent.restart(); Task { await providers.refresh() } }
                        } else {
                            Button("Dismiss") { store.error = nil }
                        }
                    }
                }
                Color.clear
                    .frame(height: max(1, composerHeight + 8))
                    .id(Self.transcriptBottomID)
            }
            .scrollTargetLayout()
            .frame(maxWidth: ChatVisualStyle.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, ChatVisualStyle.horizontalPadding)
            .padding(.top, 28)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(scrollState.followsLatest ? .bottom : nil, for: .sizeChanges)
        .scrollPosition($scrollPosition)
        .onChange(of: store.messages) { _, _ in scrollToLatestIfFollowing() }
        .onChange(of: store.activity) { _, _ in scrollToLatestIfFollowing() }
        .onChange(of: store.error) { _, _ in scrollToLatestIfFollowing() }
        .onChange(of: store.agent.startupError) { _, _ in scrollToLatestIfFollowing() }
        .onChange(of: composerHeight) { _, _ in scrollToLatestIfFollowing() }
        .onChange(of: store.isResponding) { _, responding in
            if responding { scrollState = ChatScrollState() }
            scrollToLatestIfFollowing()
        }
        .onScrollPhaseChange { _, phase in
            isScrollingTranscript = phase == .interacting || phase == .decelerating
        }
        .onScrollGeometryChange(for: ChatScrollState.Geometry.self) { geometry in
            ChatScrollState.Geometry(
                contentHeight: geometry.contentSize.height,
                viewportHeight: geometry.containerSize.height,
                visibleBottom: geometry.visibleRect.maxY
            )
        } action: { _, new in
            scrollState.update(to: new, isUserScrolling: isScrollingTranscript)
        }
        .overlay(alignment: .bottom) {
            if !scrollState.followsLatest {
                Button {
                    scrollState = ChatScrollState()
                    scrollPosition.scrollTo(id: Self.transcriptBottomID, anchor: .bottom)
                } label: {
                    Label("Jump", systemImage: "arrow.down")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(.primary)
                        .contentShape(Capsule())
                }
                .buttonStyle(FritzButtonStyle(.floating))
                .padding(.bottom, composerHeight + 24)
            }
        }
    }

    private func scrollToLatestIfFollowing() {
        guard scrollState.followsLatest, !isScrollingTranscript else { return }
        scrollPosition.scrollTo(id: Self.transcriptBottomID, anchor: .bottom)
    }

    private func synchronizeModel() {
        guard providers.hasLoadedModels, !store.isResponding else { return }
        if let selected = store.selectedModel, providers.models.contains(where: { $0.id == selected.id }) { return }
        store.selectedModel = providers.defaultModel
    }
}
