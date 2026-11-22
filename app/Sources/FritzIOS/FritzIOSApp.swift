import SwiftUI
import Textual

@main
struct FritzIOSApp: App {
    @State private var store = ChatStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ChatWorkspaceView(store: store)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        store.stop()
                        store.flush()
                    }
                }
        }
    }
}

struct ChatWorkspaceView: View {
    @Bindable var store: ChatStore
    @State private var path: [UUID] = []
    @State private var showProviders = false
    @State private var deleteTarget: Conversation?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let issue = store.storageIssue {
                    ContentUnavailableView {
                        Label("Workspace Unavailable", systemImage: "exclamationmark.circle")
                    } description: {
                        Text(issue)
                    } actions: {
                        Button("Try Again") { store.load() }
                    }
                } else if store.workspace.conversations.isEmpty {
                    VStack(spacing: 20) {
                        RavenMark()
                        Button("New Chat", systemImage: "square.and.pencil", action: newChat)
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(store.workspace.conversations) { chat in
                        NavigationLink(value: chat.id) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(chat.title)
                                if let preview = chat.messages.last(where: { !$0.content.isEmpty })?.content {
                                    Text(preview)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                deleteTarget = chat
                            }
                        }
                    }
                }
            }
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Providers", systemImage: "slider.horizontal.3") { showProviders = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !store.workspace.conversations.isEmpty {
                        Button("New Chat", systemImage: "square.and.pencil", action: newChat)
                    }
                }
            }
            .navigationDestination(for: UUID.self) { chatID in
                if let chat = store.workspace.conversations.first(where: { $0.id == chatID }) {
                    ConversationView(store: store, chat: chat, openProviders: { showProviders = true })
                }
            }
        }
        .task {
            if path.isEmpty, let selected = store.workspace.selectedID,
               store.workspace.conversations.contains(where: { $0.id == selected }) {
                path = [selected]
            }
        }
        .onChange(of: path) { _, path in store.select(path.last) }
        .sheet(isPresented: $showProviders) {
            NavigationStack { ProvidersView(store: store) }
        }
        .alert("Fritz", isPresented: Binding(
            get: { store.notice != nil },
            set: { if !$0 { store.notice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.notice ?? "")
        }
        .confirmationDialog("Delete Chat?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        ), titleVisibility: .visible, presenting: deleteTarget) { chat in
            Button("Delete Chat", role: .destructive) { store.deleteChat(chat.id) }
        } message: { chat in
            Text(chat.title)
        }
    }

    private func newChat() {
        if let id = store.newChat() { path = [id] }
    }
}

struct ConversationView: View {
    let store: ChatStore
    let chat: Conversation
    let openProviders: () -> Void
    @State private var showModels = false

    private var provider: ProviderConnection? {
        store.workspace.providers.first { $0.id == chat.providerID }
    }

    var body: some View {
        Group {
            if chat.messages.isEmpty {
                VStack(spacing: 20) {
                    RavenMark()
                    if provider == nil || chat.model.isEmpty {
                        if store.workspace.providers.isEmpty {
                            Button("Add a Provider", action: openProviders)
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Choose Model") { showModels = true }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(chat.messages) { message in
                            MessageView(message: message)
                        }
                        if let status = chat.messages.last?.status, status == .stopped || status == .failed {
                            Button("Retry Reply", systemImage: "arrow.clockwise") { store.send(chat.id, retry: true) }
                                .buttonStyle(.bordered)
                                .disabled(store.activeChatID != nil || provider == nil || chat.model.isEmpty)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                }
                .defaultScrollAnchor(.top, for: .alignment)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Message Fritz", text: Binding(
                        get: { chat.draft },
                        set: { store.updateDraft($0, chatID: chat.id) }
                    ), axis: .vertical)
                    .lineLimit(1...6)
                    .accessibilityIdentifier("chat-composer")
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 21))
                    if store.activeChatID == chat.id {
                        Button("Stop Reply", systemImage: "stop.fill") { store.stop() }
                            .accessibilityIdentifier("stop-reply")
                    } else {
                        Button("Send Message", systemImage: "arrow.up") { store.send(chat.id) }
                            .accessibilityIdentifier("send-message")
                            .disabled(store.activeChatID != nil || provider == nil || chat.model.isEmpty ||
                                      chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .labelStyle(.iconOnly)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .background(.bar)
        }
        .navigationTitle(chat.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if store.workspace.providers.isEmpty { openProviders() } else { showModels = true }
                } label: {
                    VStack(alignment: .trailing, spacing: 1) {
                        if let provider {
                            Text(provider.name).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(provider == nil || chat.model.isEmpty ? "Choose Model" : chat.model)
                            .font(.caption.weight(.semibold))
                    }
                    .lineLimit(1)
                    .frame(maxWidth: 130, alignment: .trailing)
                }
                .accessibilityIdentifier("choose-model")
                .disabled(store.activeChatID == chat.id)
            }
        }
        .sheet(isPresented: $showModels) {
            NavigationStack { ChatModelView(store: store, chat: chat) }
        }
    }
}

private struct RavenMark: View {
    var body: some View {
        Image("Raven")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 66, height: 54)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

private struct MessageView: View {
    let message: ChatMessage

    var body: some View {
        if message.role == .user {
            Text(message.content)
                .textSelection(.enabled)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 19))
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Fritz")
                    .font(.subheadline.weight(.semibold))
                if !message.content.isEmpty {
                    StructuredText(markdown: message.content)
                        .textual.structuredTextStyle(.gitHub)
                        .textual.imageAttachmentLoader(ChatImageLoader())
                        .textual.textSelection(.enabled)
                }
                switch message.status {
                case .streaming:
                    if message.content.isEmpty { ProgressView("Waiting for reply") }
                case .stopped:
                    Text("Reply stopped").font(.footnote).foregroundStyle(.secondary)
                case .failed:
                    Text("Reply failed").font(.footnote).foregroundStyle(.secondary)
                case nil:
                    EmptyView()
                }
            }
        }
    }
}

// Rendering model output must not load images or tracking pixels from the network.
private struct ChatImageLoader: AttachmentLoader {
    func attachment(for url: URL, text: String, environment: ColorEnvironmentValues) async throws -> AnyAttachment {
        throw ChatFailure("Remote images are disabled in chat.")
    }
}
