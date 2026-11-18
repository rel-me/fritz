import Inferno
import FritzUI
import Fritz
import SwiftUI

struct ChatView: View {
    @Bindable var store: ChatStore
    let providers: ProviderStore
    let localModels: LocalModelRuntimeStore
    let openModels: (ModelsLocation) -> Void
    let headerBottom: CGFloat
    @State private var setupModel: ChatModelOption?
    @State private var selectionTask: Task<Void, Never>?
    @State private var isPreparingModel = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var isFocused: Bool
    @State private var composerHeight: CGFloat = 0
    @State private var scrollState = ChatScrollState()
    @State private var scrollPosition = ScrollPosition(idType: String.self, edge: .bottom)
    @State private var isScrollingTranscript = false
    @State private var bodyEntry: ChatMessage?
    @State private var contentOffset: CGFloat = 0
    @State private var offsets: [UUID: CGFloat] = [:]
    @State private var restoreAnchor: (UUID, CGFloat)?
    private static let transcriptBottomID = "chat-transcript-bottom"

    var body: some View {
        ZStack(alignment: .bottom) {
            transcript

            VStack(alignment: .trailing, spacing: 8) {
                ChatComposer(
                    draft: $store.draft,
                    placeholder: store.messages.isEmpty ? "Ask Fritz anything" : "Ask for follow-up changes",
                    canSend: store.canSend && !isPreparingModel,
                    isPreparingModel: isPreparingModel,
                    isResponding: store.isResponding,
                    isFocused: $isFocused,
                    models: providers.pickerModels,
                    recentModels: providers.recentModels,
                    modelProviders: providers.providerOrder,
                    selectedModel: store.selectedModel,
                    selectedEffort: store.effort,
                    selectedSpeed: store.speed,
                    selectModel: chooseModel,
                    selectEffort: { store.effort = $0 },
                    selectSpeed: { store.speed = $0 },
                    configureModels: { openModels(.remote) },
                    configureLocalModels: { openModels(.local) },
                    send: {
                        guard !isPreparingModel else { return }
                        if let model = store.selectedModel { providers.record(model) }
                        store.send()
                    },
                    stop: store.stop
                )
                .disabled(!store.isReady)
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
        .sheet(item: $setupModel) { model in
            ModelsProviderEditor(store: providers, localModels: localModels,
                                 existing: providers.setupConnection(for: model), initialModel: model) { connection in
                let selected = ChatModelOption(connection: connection,
                    model: DiscoveredAIModel(id: connection.modelID, displayName: model.displayName))
                store.select(selected)
                providers.record(selected)
            }
        }
        .onAppear(perform: synchronizeModel)
        .onDisappear { selectionTask?.cancel() }
        .onChange(of: providers.models) { _, _ in synchronizeModel() }
        .onChange(of: providers.hasLoadedModels) { _, _ in synchronizeModel() }
        .onChange(of: store.isReady) { _, _ in synchronizeModel() }
        .sheet(item: $bodyEntry) { entry in
            ChatStoredBody(entry: entry, repository: store.repository)
        }
        .onChange(of: store.isResponding) { _, responding in if !responding { synchronizeModel() } }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: ChatVisualStyle.transcriptSpacing) {
                if store.hasOlder {
                    Button("Load Older Messages") { loadHistory(older: true) }
                        .disabled(store.isPaging)
                }
                ForEach(store.messages) { message in
                    let isActive = store.activeEntryID == message.id
                    ChatMessageRow(
                        message: message,
                        isActive: isActive,
                        activity: isActive ? store.activity : nil,
                        activeTools: isActive ? store.activeTools : [],
                        repository: store.repository,
                        openBody: { bodyEntry = message }
                    )
                    .modifier(ChatHeaderBlur(isEnabled: !reduceTransparency, headerBottom: headerBottom))
                    .id(message.id.uuidString)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).minY } action: { offset in
                        offsets[message.id] = offset
                        if let (id, target) = restoreAnchor, id == message.id {
                            restoreAnchor = nil
                            scrollPosition.scrollTo(y: contentOffset + offset - target)
                        }
                    }
                    .onDisappear { offsets.removeValue(forKey: message.id) }
                }
                if store.hasNewer {
                    Button("Load Newer Messages") { loadHistory(older: false) }
                        .disabled(store.isPaging)
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
                    .modifier(ChatHeaderBlur(isEnabled: !reduceTransparency, headerBottom: headerBottom))
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
        .scrollClipDisabled(extendsTranscriptBehindToolbar)
        .defaultScrollAnchor(scrollState.followsLatest ? .bottom : nil, for: .sizeChanges)
        .scrollPosition($scrollPosition)
        .onChange(of: store.messages.last?.content) { _, _ in scrollToLatestIfFollowing() }
        .onChange(of: store.messages.last?.id) { _, _ in scrollToLatestIfFollowing() }
        .onChange(of: store.windowRevision) { _, _ in scrollToLatestIfFollowing() }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
            contentOffset = offset
        }
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
        } action: { old, new in
            if !store.hasNewer { scrollState.update(to: new, isUserScrolling: isScrollingTranscript) }
            if isScrollingTranscript && new.visibleBottom < new.viewportHeight + 96 && store.hasOlder {
                loadHistory(older: true)
            }
            if old.contentHeight != new.contentHeight || old.viewportHeight != new.viewportHeight {
                scrollToLatestIfFollowing()
            }
        }
        .overlay(alignment: .bottom) {
            if !scrollState.followsLatest {
                Button {
                    restoreAnchor = nil
                    Task {
                        await store.latest()
                        scrollState = ChatScrollState()
                        scrollPosition.scrollTo(edge: .bottom)
                    }
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
        guard scrollState.followsLatest, !isScrollingTranscript, !store.hasNewer, restoreAnchor == nil else { return }
        scrollPosition.scrollTo(edge: .bottom)
    }

    private func chooseModel(_ model: ChatModelOption) {
        guard !store.isResponding, selectionTask == nil else { return }
        guard model.provider == .fritz else {
            if model.connectionID != nil { store.select(model); providers.record(model) }
            else { setupModel = model }
            return
        }
        isPreparingModel = true
        selectionTask = Task {
            defer { isPreparingModel = false; selectionTask = nil }
            do {
                if let ready = try await providers.prepareLocalModel(model) {
                    try Task.checkCancellation()
                    store.select(ready); providers.record(ready)
                } else {
                    try Task.checkCancellation()
                    setupModel = model
                }
            } catch is CancellationError {
            } catch { store.error = error.localizedDescription }
        }
    }

    private func loadHistory(older: Bool) {
        guard !store.isPaging else { return }
        scrollState = ChatScrollState(followsLatest: false)
        let visibleID = scrollPosition.viewID(type: String.self).flatMap { UUID(uuidString: $0) }
        let anchor = visibleID.flatMap { id in offsets[id].map { (id, $0) } }
        restoreAnchor = anchor
        Task {
            if older { await store.older() } else { await store.newer() }
            if let (id, _) = restoreAnchor {
                if store.messages.contains(where: { $0.id == id }) {
                    scrollPosition.scrollTo(id: id.uuidString, anchor: .top)
                } else {
                    restoreAnchor = nil
                }
            }
        }
    }

    private func synchronizeModel() {
        guard store.isReady, providers.hasLoadedModels, !store.isResponding, !isPreparingModel else { return }
        store.synchronizeModel(models: providers.models, defaultModel: providers.defaultModel)
    }
}

private struct ChatHeaderBlur: ViewModifier {
    let isEnabled: Bool
    let headerBottom: CGFloat
    @State private var contentFrame: CGRect = .zero
    private let blurRadius: CGFloat = 24

    private var overlapsHeader: Bool {
        contentFrame.minY < headerBottom && contentFrame.maxY > 0
    }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .onGeometryChange(for: CGRect.self) { geometry in
                    geometry.frame(in: .global)
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
                            .environment(\.chatIsVisualEffectCopy, true)
                            // Inferno samples out to three times its radius. Give the
                            // shader transparent space without reflowing the message.
                            .frame(width: contentFrame.width)
                            .padding(.horizontal, blurRadius * 3)
                            .variableBlur(radius: blurRadius, maxSampleCount: 24) { geometry, context in
                                let start = headerBottom - 28 - contentFrame.minY
                                context.fill(
                                    Path(CGRect(origin: .zero, size: geometry.size)),
                                    with: .linearGradient(
                                        Gradient(colors: [.white, .clear]),
                                        startPoint: CGPoint(x: 0, y: start),
                                        endPoint: CGPoint(x: 0, y: start + 28)
                                    )
                                )
                            }
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
        let height = max(1, contentFrame.height)
        // Finish the transition inside the header so transcript content below stays sharp.
        return LinearGradient(
            colors: blurred ? [.white, .clear] : [.clear, .white],
            startPoint: UnitPoint(x: 0, y: (headerBottom - 28 - contentFrame.minY) / height),
            endPoint: UnitPoint(x: 0, y: (headerBottom - contentFrame.minY) / height)
        )
    }
}
