import FritzUpdates
import Fritz
import SwiftUI

enum FritzSettingsTab: String, CaseIterable, Identifiable {
    case general
    case providers
    case localModels
    case service
    case debug

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .providers: "Model Providers"
        case .localModels: "Local Models"
        case .service: "Service"
        case .debug: "Debug"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .providers: "cpu"
        case .localModels: "server.rack"
        case .service: "gearshape.2"
        case .debug: "ladybug"
        }
    }
}

struct FritzSettingsView: View {
    @Bindable var state: FritzState
    @ObservedObject var updater: AppUpdater
    @State private var editor: ProviderEditorSelection?
    @State private var showsDownload = false

    var body: some View {
        GeometryReader { geometry in
            NavigationSplitView {
                List(selection: selection) {
                    ForEach(FritzSettingsTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.systemImage).tag(tab)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(FritzWindowStyle.workspaceBackground)
                .navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 280)
            } detail: {
                Group {
                    switch state.settingsTab {
                    case .general:
                        FritzGeneralSettingsView(updater: updater, settings: state.settings)
                    case .providers:
                        ProvidersView(store: state.providers, editor: $editor,
                                      openLocalModels: { state.selectSettings(.localModels) },
                                      downloadModel: { showsDownload = true })
                    case .localModels:
                        LocalModelsView(store: state.localModels,
                                        downloadModel: { showsDownload = true })
                    case .service:
                        FritzServiceSettingsView(agent: state.agent)
                    case .debug:
                        Text("Debug")
                            .font(.headline)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(24)
                            .background(FritzWindowStyle.contentBackground)
                    }
                }
                // Settings can measure lists with an oversized ideal height; keep the detail inside the window.
                .frame(height: max(0, geometry.size.height - 80))
                .clipShape(RoundedRectangle(cornerRadius: FritzWindowStyle.cornerRadius, style: .continuous))
                .padding(.leading, 4).padding(.trailing, 8).padding(.bottom, 8)
            }
            .navigationSplitViewStyle(.prominentDetail)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .fritzWindowBackground()
        .frame(minWidth: 800, minHeight: 500)
        .sheet(item: $editor) { ProviderEditor(store: state.providers, existing: $0.connection, initialCategory: $0.category) }
        .sheet(isPresented: $showsDownload, onDismiss: {
            Task {
                await state.localModels.refresh()
                await state.providers.refresh()
            }
        }) {
            LocalModelDownloadSheet(agent: state.agent)
        }
    }

    private var selection: Binding<FritzSettingsTab?> {
        Binding(
            get: { state.settingsTab },
            set: { if let tab = $0 { state.selectSettings(tab) } }
        )
    }
}

private struct FritzGeneralSettingsView: View {
    @ObservedObject var updater: AppUpdater
    @Bindable var settings: AppSettings
    @State private var installResult: CommandLineInstaller.InstallResult?

    var body: some View {
        Form {
            Section {
                LabeledContent("Appearance") {
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            } header: {
                settingsTitle("General")
            } footer: {
                Text("System follows the appearance selected in macOS.")
            }

            Section {
                LabeledContent("Update Channel") {
                    Picker("Update Channel", selection: $settings.updateChannel) {
                        ForEach(AppUpdateChannel.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            } header: {
                Text("Updates")
            } footer: {
                Text(updater.isConfigured
                     ? "Beta includes preview releases. Dev also includes development builds."
                     : "Updates are unavailable in this build. Beta includes preview releases; Dev also includes development builds.")
            }

            Section {
                LabeledContent("Fritz Command Line") {
                    Button("Install Command Line") {
                        installResult = CommandLineInstaller().install()
                    }
                }
            } header: {
                Text("Command Line")
            } footer: {
                if let installResult {
                    Label(installResult.message, systemImage: installResult.systemImage)
                        .textSelection(.enabled)
                } else {
                    Text("Installs a fritz symlink in a writable folder in PATH. Fritz must be installed in /Applications.")
                }
            }
        }
        .fritzSettingsFormStyle()
        .safeAreaInset(edge: .bottom) {
            if let error = settings.error { Text(error).foregroundStyle(.orange).textSelection(.enabled).padding() }
        }
        .onChange(of: settings.appearance) { _, value in
            (AppAppearance(rawValue: value) ?? .system).apply(to: NSApplication.shared)
        }
        .onChange(of: settings.updateChannel) { _, value in
            updater.setUpdateChannel(AppUpdateChannel(rawValue: value) ?? .release)
        }
    }
}

private struct FritzServiceSettingsView: View {
    let agent: AgentClient

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Label(agent.isRunning ? "Connected" : "Stopped",
                          systemImage: agent.isRunning ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(agent.isRunning ? .green : .secondary)
                }
                LabeledContent("Connection", value: "Private stdin/stdout pipes")
                LabeledContent("Owner", value: "Fritz.app")
            } header: {
                settingsTitle("Service")
            } footer: {
                if let error = agent.startupError {
                    Text(error).foregroundStyle(.orange).textSelection(.enabled)
                } else {
                    Text("Fritz supervises its bundled agent. Each active chat uses a separate fritz-harness process.")
                }
            }
        }
        .fritzSettingsFormStyle()
    }
}

private func settingsTitle(_ title: String) -> some View {
    Text(title)
        .font(.headline)
        .foregroundStyle(.primary)
        .accessibilityAddTraits(.isHeader)
        .listRowBackground(Color.clear)
}

private extension CommandLineInstaller.InstallResult {
    var message: String {
        switch self {
        case let .installed(url): "Installed fritz at \(url.path)."
        case let .alreadyInstalled(url): "fritz is already installed at \(url.path)."
        case .appNotInstalled: "Install Fritz in /Applications, then try again."
        case .noAvailableDirectory: "No writable folder in PATH is available."
        case let .failed(message): "Could not install fritz: \(message)"
        }
    }

    var systemImage: String {
        switch self {
        case .installed, .alreadyInstalled: "checkmark.circle.fill"
        case .appNotInstalled, .noAvailableDirectory, .failed: "exclamationmark.triangle.fill"
        }
    }
}
