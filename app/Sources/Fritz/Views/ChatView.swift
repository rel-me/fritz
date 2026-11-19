import Inferno
import FritzUI
import Fritz
import SwiftUI

struct ChatView: View {
    @Bindable var store: ChatStore
    let providers: ProviderStore
    let localModels: LocalModelRuntimeStore
    let openModels: (ModelsLocation) -> Void
    let headerFrame: CGRect
    let isProjectFolderAvailable: Bool
    let isArchived: Bool
    @State private var setupModel: ChatModelOption?
    @State private var selectionTask: Task<Void, Never>?
    @State private var isPreparingModel = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var isFocused: Bool
    @State private var composerHeight: CGFloat = 0
    @State private var scrollState = ChatScrollState()
    @State private var scrollPosition = ScrollPosition(idType: UUID.self, edge: .bottom)
    @State private var isScrollingTranscript = false
    @State private var bodyEntry: ChatMessage?
    @State private var viewportHeight: CGFloat = 0
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var historyAnchor: HistoryAnchor?

    private var canCompose: Bool { isProjectFolderAvailable && !isArchived }

    var body: some View {
        ZStack(alignment: .bottom) {
            transcript

            VStack(alignment: .trailing, spacing: 8) {
                if canCompose {
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
                        stop: store.stopByUser
                    )
                    .disabled(!store.isReady)
                } else {
                    Label(isArchived ? "Archived chat. Restore it in Settings to continue chatting."
                                    : "Project folder unavailable. Reconnect it from the project’s context menu to continue chatting.",
                          systemImage: isArchived ? "archivebox" : "folder.badge.questionmark")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(ChatVisualStyle.pageBackground, in: RoundedRectangle(cornerRadius: ChatVisualStyle.composerCornerRadius))
                }
            }
            .frame(maxWidth: ChatVisualStyle.contentMaxWidth)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
            .padding(.horizontal, 6)
            .padding(.top, 12)
            .padding(.bottom, 6)
        }
        .background(ChatVisualStyle.pageBackground)
        .onExitCommand(perform: store.stopByUser)
        .defaultFocus($isFocused, true)
        .task {
            // Let the previous thread release its field before focusing this one.
            await Task.yield()
            guard !Task.isCancelled, store.isReady else { return }
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
        .onChange(of: canCompose) { _, available in
            if available {
                synchronizeModel()
                isFocused = true
            }
        }
        .onChange(of: store.isReady) { _, ready in
            if ready {
                synchronizeModel()
                isFocused = true
            }
        }
        .sheet(item: $bodyEntry) { entry in
            ChatStoredBody(entry: entry, repository: store.repository)
        }
        .onChange(of: store.isResponding) { _, responding in if !responding { synchronizeModel() } }
    }

    private var transcript: some View {
        ScrollView {
            // ChatStore bounds this window. Measure Markdown rows so paging can
            // restore the reading position using their actual heights.
            VStack(alignment: .leading, spacing: ChatVisualStyle.transcriptSpacing) {
                if store.hasOlder {
                    Button("Load Older Messages") { loadHistory(older: true) }
                        .disabled(store.isPaging)
                }
                ForEach(store.messages) { message in
                    let isActive = store.activeEntryID == message.id
                    let isEdge = message.id == store.messages.first?.id || message.id == store.messages.last?.id
                    ChatMessageRow(
                        message: message,
                        isActive: isActive,
                        activity: isActive ? store.activity : nil,
                        activeTools: isActive ? store.activeTools : [],
                        repository: store.repository,
                        openBody: { bodyEntry = message }
                    )
                    .modifier(ChatHeaderBlur(isEnabled: !reduceTransparency, headerFrame: headerFrame))
                    .onGeometryChange(for: CGRect?.self) { proxy in
                        isEdge ? proxy.frame(in: .scrollView) : nil
                    } action: { frame in
                        rowFrames[message.id] = frame
                    }
                    .onDisappear { rowFrames.removeValue(forKey: message.id) }
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
                    .modifier(ChatHeaderBlur(isEnabled: !reduceTransparency, headerFrame: headerFrame))
                }
                Color.clear
                    .frame(height: max(1, composerHeight + 8))
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
        .onChange(of: historyAnchor) { _, anchor in
            guard let anchor else { return }
            // The updated scroll targets are registered after this view update.
            DispatchQueue.main.async {
                guard historyAnchor == anchor else { return }
                scrollPosition.scrollTo(id: anchor.id, anchor: UnitPoint(x: 0.5, y: anchor.offset))
                historyAnchor = nil
            }
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
            viewportHeight = new.viewportHeight
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
                    historyAnchor = nil
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
        guard scrollState.followsLatest, !isScrollingTranscript, !store.hasNewer else { return }
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
        // Loading is triggered at a transcript edge. Keep the old edge
        // message visible, with its measured offset when it was on screen.
        guard let id = (older ? store.messages.first : store.messages.last)?.id else { return }
        let frame = rowFrames[id]
        let distance = viewportHeight - (frame?.height ?? 0)
        let offset = abs(distance) > 1 ? (frame?.minY ?? 0) / distance : 0
        Task {
            let revision = store.windowRevision
            if older { await store.older() } else { await store.newer() }
            guard store.windowRevision != revision, store.messages.contains(where: { $0.id == id }) else { return }
            historyAnchor = HistoryAnchor(id: id, offset: offset)
        }
    }

    private struct HistoryAnchor: Equatable {
        let id: UUID
        let offset: CGFloat
    }

    private func synchronizeModel() {
        guard canCompose, store.isReady, providers.hasLoadedModels, !store.isResponding, !isPreparingModel else { return }
        store.synchronizeModel(models: providers.models, defaultModel: providers.defaultModel)
    }
}

private struct ChatHeaderBlur: ViewModifier {
    let isEnabled: Bool
    let headerFrame: CGRect
    @State private var contentFrame: CGRect = .zero
    private let blurRadius: CGFloat = 24

    private var overlapsHeader: Bool {
        !headerFrame.isEmpty && contentFrame.minY < headerFrame.maxY && contentFrame.maxY > headerFrame.minY
    }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .onGeometryChange(for: CGRect.self) { geometry in
                    geometry.frame(in: .global)
                } action: { contentFrame = $0 }
                .overlay {
                    if overlapsHeader {
                        // An alpha mask on the original row flattens its text into
                        // a composited layer, even below the toolbar.
                        headerFade(from: ChatVisualStyle.pageBackground)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
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
                                let start = headerFrame.minY - contentFrame.minY
                                context.fill(
                                    Path(CGRect(origin: .zero, size: geometry.size)),
                                    with: .linearGradient(
                                        Gradient(colors: [.white, .clear]),
                                        startPoint: CGPoint(x: 0, y: start),
                                        endPoint: CGPoint(x: 0, y: start + headerFrame.height)
                                    )
                                )
                            }
                            .opacity(0.3)
                            .mask { headerFade(from: .white) }
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
        } else {
            content
        }
    }

    private func headerFade(from color: Color) -> some View {
        let height = max(1, contentFrame.height)
        // Keep only the blurred copy behind the toolbar. Crossfade to the
        // sharp original within the bottom of the heading.
        let fadeStart = max(headerFrame.minY, headerFrame.maxY - 28)
        return LinearGradient(
            colors: [color, color.opacity(0)],
            startPoint: UnitPoint(x: 0, y: (fadeStart - contentFrame.minY) / height),
            endPoint: UnitPoint(x: 0, y: (headerFrame.maxY - contentFrame.minY) / height)
        )
    }
}
