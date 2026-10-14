import FritzUI
import Fritz
import SwiftUI

struct ChatView: View {
    @Bindable var store: ChatStore
    let providers: ProviderStore
    let openProviders: () -> Void
    let addProvider: (AIProviderPreset?) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var isFocused: Bool
    @State private var composerHeight: CGFloat = 0
    @State private var scrollState = ChatScrollState()
    @State private var scrollPosition = ScrollPosition(idType: String.self, edge: .bottom)
    @State private var isScrollingTranscript = false
    @State private var headerScrollGeometry = ChatHeaderScrollGeometry()
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
                    configuredProviderIDs: Set(providers.connections.map {
                        AIProviderPreset.matching(provider: $0.provider, baseURL: $0.baseURL).id
                    }),
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
            // Markdown reflows when the window or inspector changes width. Measure
            // every row so scroll bounds and bottom anchoring use actual heights.
            VStack(alignment: .leading, spacing: ChatVisualStyle.transcriptSpacing) {
                ForEach(store.messages) { message in
                    ChatMessageRow(
                        message: message,
                        isActive: store.isResponding && message.id == store.messages.last?.id,
                        activity: store.activity
                    )
                    .modifier(ChatHeaderBlur(isEnabled: !reduceTransparency, scrollGeometry: headerScrollGeometry))
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
                    .modifier(ChatHeaderBlur(isEnabled: !reduceTransparency, scrollGeometry: headerScrollGeometry))
                }
                Color.clear
                    .frame(height: max(1, composerHeight + 8))
                    .id(Self.transcriptBottomID)
            }
            .coordinateSpace(name: ChatHeaderCoordinateSpace.transcript)
            .scrollTargetLayout()
            .frame(maxWidth: ChatVisualStyle.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, ChatVisualStyle.horizontalPadding)
            .padding(.top, 28)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollClipDisabled(extendsTranscriptBehindToolbar)
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
        .onScrollGeometryChange(for: ChatHeaderScrollGeometry.self) { geometry in
            ChatHeaderScrollGeometry(offset: geometry.contentOffset.y,
                                     headerBottom: geometry.contentInsets.top)
        } action: { _, geometry in
            headerScrollGeometry = geometry
        }
        .onScrollGeometryChange(for: ChatScrollState.Geometry.self) { geometry in
            ChatScrollState.Geometry(
                contentHeight: geometry.contentSize.height,
                viewportHeight: geometry.containerSize.height,
                visibleBottom: geometry.visibleRect.maxY
            )
        } action: { old, new in
            scrollState.update(to: new, isUserScrolling: isScrollingTranscript)
            if old.contentHeight != new.contentHeight || old.viewportHeight != new.viewportHeight {
                scrollToLatestIfFollowing()
            }
        }
        .overlay(alignment: .bottom) {
            if !scrollState.followsLatest {
                Button {
                    scrollState = ChatScrollState()
                    scrollPosition.scrollTo(edge: .bottom)
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

    private var extendsTranscriptBehindToolbar: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    private func scrollToLatestIfFollowing() {
        guard scrollState.followsLatest, !isScrollingTranscript else { return }
        scrollPosition.scrollTo(edge: .bottom)
    }

    private func synchronizeModel() {
        guard providers.hasLoadedModels, !store.isResponding else { return }
        if let selected = store.selectedModel, let current = providers.models.first(where: { $0.id == selected.id }) {
            if current != selected { store.select(current) }
            return
        }
        if let model = providers.defaultModel { store.select(model) }
        else { store.selectedModel = nil }
    }
}

private enum ChatHeaderCoordinateSpace: Hashable {
    case transcript
}

private struct ChatHeaderScrollGeometry: Equatable {
    var offset: CGFloat = 0
    var headerBottom: CGFloat = 0
}

private struct ChatHeaderBlur: ViewModifier {
    let isEnabled: Bool
    let scrollGeometry: ChatHeaderScrollGeometry
    @State private var contentFrame: CGRect = .zero

    private var viewportFrame: CGRect {
        contentFrame.offsetBy(dx: 0, dy: 28 - scrollGeometry.offset)
    }

    private var overlapsHeader: Bool {
        viewportFrame.minY < scrollGeometry.headerBottom + 28 && viewportFrame.maxY > 0
    }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .onGeometryChange(for: CGRect.self) { geometry in
                    geometry.frame(in: .named(ChatHeaderCoordinateSpace.transcript))
                } action: { contentFrame = $0 }
                .mask {
                    if overlapsHeader {
                        edgeMask(blurred: false)
                    } else {
                        Color.white
                    }
                }
                .overlay {
                    if overlapsHeader && isEnabled {
                        content
                            .blur(radius: 24)
                            .opacity(0.3)
                            .mask { edgeMask(blurred: true) }
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
        } else {
            content
        }
    }

    private func edgeMask(blurred: Bool) -> some View {
        let height = max(1, viewportFrame.height)
        // Blur actual scrolling content, then blend into sharp text below the title.
        return LinearGradient(
            colors: blurred ? [.white, .clear] : [.clear, .white],
            startPoint: UnitPoint(x: 0, y: (scrollGeometry.headerBottom - viewportFrame.minY) / height),
            endPoint: UnitPoint(x: 0, y: (scrollGeometry.headerBottom + 28 - viewportFrame.minY) / height)
        )
    }
}
