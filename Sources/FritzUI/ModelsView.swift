import AppKit
import SwiftUI

/// A Models page driven by the host's provider, model and runtime state.
public struct ModelsView<ProviderID: Hashable, SessionID: Hashable, TransferActions: View>: View {
  public enum Page: Hashable { case providers, localModels }

  @Binding private var selectedProviderIDs: Set<ProviderID>
  @State private var page: Page
  @State private var search = ""
  private let providers: [ModelProviderItem<ProviderID>]
  private let sessions: [LocalModelSessionItem<SessionID>]
  private let showsLocalModels: Bool
  private let isLoadingProviders: Bool
  private let isLoadingLocalModels: Bool
  private let providerError: String?
  private let localModelError: String?
  private let background: Color
  private let actionControlSize: ControlSize
  private let transferActions: TransferActions
  private let addProvider: () -> Void
  private let downloadModels: () -> Void
  private let editProvider: (ProviderID) -> Void
  private let canMakeDefault: (ProviderID) -> Bool
  private let showsMakeDefault: (ProviderID) -> Bool
  private let makeDefault: (ProviderID) -> Void
  private let exportProviders: (Set<ProviderID>) -> Void
  private let deleteProvider: (ProviderID) -> Void
  private let startSession: (SessionID) -> Void
  private let stopSession: (SessionID) -> Void
  private let restartSession: (SessionID) -> Void

  public init(
    providers: [ModelProviderItem<ProviderID>],
    selectedProviderIDs: Binding<Set<ProviderID>>,
    sessions: [LocalModelSessionItem<SessionID>] = [],
    showsLocalModels: Bool = false,
    initialPage: Page = .providers,
    isLoadingProviders: Bool = false,
    isLoadingLocalModels: Bool = false,
    providerError: String? = nil,
    localModelError: String? = nil,
    background: Color = .clear,
    actionControlSize: ControlSize = .large,
    @ViewBuilder transferActions: () -> TransferActions,
    addProvider: @escaping () -> Void,
    downloadModels: @escaping () -> Void = {},
    editProvider: @escaping (ProviderID) -> Void,
    canMakeDefault: @escaping (ProviderID) -> Bool = { _ in false },
    showsMakeDefault: @escaping (ProviderID) -> Bool = { _ in true },
    makeDefault: @escaping (ProviderID) -> Void = { _ in },
    exportProviders: @escaping (Set<ProviderID>) -> Void = { _ in },
    deleteProvider: @escaping (ProviderID) -> Void,
    startSession: @escaping (SessionID) -> Void = { _ in },
    stopSession: @escaping (SessionID) -> Void = { _ in },
    restartSession: @escaping (SessionID) -> Void = { _ in }
  ) {
    self.providers = providers
    _selectedProviderIDs = selectedProviderIDs
    _page = State(initialValue: initialPage)
    self.sessions = sessions
    self.showsLocalModels = showsLocalModels
    self.isLoadingProviders = isLoadingProviders
    self.isLoadingLocalModels = isLoadingLocalModels
    self.providerError = providerError
    self.localModelError = localModelError
    self.background = background
    self.actionControlSize = actionControlSize
    self.transferActions = transferActions()
    self.addProvider = addProvider
    self.downloadModels = downloadModels
    self.editProvider = editProvider
    self.canMakeDefault = canMakeDefault
    self.showsMakeDefault = showsMakeDefault
    self.makeDefault = makeDefault
    self.exportProviders = exportProviders
    self.deleteProvider = deleteProvider
    self.startSession = startSession
    self.stopSession = stopSession
    self.restartSession = restartSession
  }

  public var body: some View {
    VStack(spacing: 0) {
      if page == .providers {
        ModelProvidersTable(providers: visibleProviders, selection: $selectedProviderIDs,
                            isLoading: isLoadingProviders, edit: editProvider)
          .contextMenu(forSelectionType: ProviderID.self) { ids in
            if ids.count == 1, let id = ids.first, providers.contains(where: { $0.id == id }) {
              Button("Edit Models", systemImage: "pencil") { editProvider(id) }
              if showsMakeDefault(id) {
                Button("Make Default", systemImage: "checkmark.circle") { makeDefault(id) }
                  .disabled(!canMakeDefault(id))
              }
              Divider()
            }
            if ids.count == 1, let id = ids.first, providers.contains(where: { $0.id == id }) {
              Button("Delete", role: .destructive) { deleteProvider(id) }
            }
            if !ids.isEmpty {
              Button("Export",
                     systemImage: "square.and.arrow.up") { exportProviders(ids) }
            }
          } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { editProvider(id) }
          }
          .onDeleteCommand {
            if selectedProviderIDs.count == 1, let id = selectedProviderIDs.first {
              deleteProvider(id)
            }
          }
        if let providerError { errorLabel(providerError) }
      } else if sessions.isEmpty && !isLoadingLocalModels {
        ContentUnavailableView {
          Label("No Local Models", systemImage: "cpu")
        } description: {
          Text("Download a model to use it in a chat.")
        } actions: {
          Button("Download Models", action: downloadModels)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        if let localModelError { errorLabel(localModelError) }
      } else {
        LocalModelSessionsList(sessions: visibleSessions, start: startSession,
                               stop: stopSession, restart: restartSession)
        if let localModelError { errorLabel(localModelError) }
      }
    }
    .navigationTitle("Models")
    .searchable(text: $search, placement: .toolbar, prompt: "Search Models")
    .toolbar {
      ToolbarItemGroup {
        if showsLocalModels {
          Picker("Models", selection: $page) {
            Text("Providers").tag(Page.providers)
            Text("Local Models").tag(Page.localModels)
          }.pickerStyle(.menu)
        }
        if page == .providers { transferActions }
        Button("Download Models", systemImage: "arrow.down", action: downloadModels)
          .help("Download Models")
        if page == .providers {
          Button("Add Provider", systemImage: "plus", action: addProvider).help("Add Provider")
        }
      }
    }
  }

  private var visibleProviders: [ModelProviderItem<ProviderID>] {
    providers.filter { search.isEmpty || $0.name.localizedStandardContains(search)
      || ($0.models?.localizedStandardContains(search) == true) }
  }

  private var visibleSessions: [LocalModelSessionItem<SessionID>] {
    sessions.filter { search.isEmpty || $0.modelName.localizedStandardContains(search)
      || $0.modelID.localizedStandardContains(search) || $0.scope.localizedStandardContains(search) }
  }

  private func errorLabel(_ message: String) -> some View {
    Label(message, systemImage: "exclamationmark.triangle")
      .foregroundStyle(.orange)
      .textSelection(.enabled)
      .padding(12)
  }

}
