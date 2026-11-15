import FritzUpdates
import Fritz
import FritzUI
import SwiftUI

enum FritzSettingsTab: String, CaseIterable, Identifiable {
    case general
    case providers
    case service
    case debug

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .providers: "Models"
        case .service: "Service"
        case .debug: "Debug"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .providers: "cpu"
        case .service: "gearshape.2"
        case .debug: "ladybug"
        }
    }
}

struct FritzSettingsView: View {
    @Bindable var state: FritzState
    @ObservedObject var updater: AppUpdater

    var body: some View {
        GeometryReader { geometry in
            NavigationSplitView(columnVisibility: .constant(.all)) {
                List(selection: selection) {
                    ForEach(FritzSettingsTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.systemImage).tag(tab)
                    }
                }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 280)
                .toolbar(removing: .sidebarToggle)
            } detail: {
                Group {
                    switch state.settingsTab {
                    case .general:
                        FritzGeneralSettingsView(updater: updater, settings: state.settings)
                    case .providers:
                        ModelsConfigurationScreen(store: state.providers, runtime: state.localModels)
                    case .service:
                        FritzServiceSettingsView(agent: state.agent, localModels: state.localModels)
                    case .debug:
                        Text("Debug")
                            .font(.headline)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(24)
                    }
                }
            }
            .navigationSplitViewStyle(.prominentDetail)
            .navigationTitle(state.settingsTab.title)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .fritzWindowBackground()
        .frame(minWidth: 800, minHeight: 500)
        .sheet(isPresented: $state.showsLocalModelDownload, onDismiss: {
            Task {
                await state.localModels.refresh()
                await state.providers.refresh()
            }
        }) {
            NavigationStack { LocalModelDownloadSheet(store: state.providers, hardware: .current) }
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
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                LabeledContent("Update Channel") {
                    Picker("Update Channel", selection: $settings.updateChannel) {
                        ForEach(AppUpdateChannel.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                LabeledContent("Fritz Command Line") {
                    Button("Install Command Line") {
                        installResult = CommandLineInstaller().install()
                    }
                }
            } footer: {
                if let installResult {
                    Label(installResult.message, systemImage: installResult.systemImage)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
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
    let localModels: LocalModelRuntimeStore

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
            } footer: {
                if let error = agent.startupError {
                    Text(error).foregroundStyle(.orange).textSelection(.enabled)
                } else {
                    Text("Fritz supervises its bundled agent. Each active chat uses a separate fritz-harness process.")
                }
            }
            Section {
                LabeledContent("Status", value: localModels.service.status.title)
                if let pid = localModels.service.processID { LabeledContent("Process ID", value: String(pid)) }
                if let address = localModels.service.address {
                    LabeledContent("Address") { Text(address).textSelection(.enabled) }
                }
            } header: {
                Text("Local API")
            } footer: {
                if let error = localModels.service.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
    }
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
