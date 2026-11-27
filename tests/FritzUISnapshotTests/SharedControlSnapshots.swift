import AppKit
import Bonsplit
@testable import FritzUI
import Fritz
import Observation
import SwiftUI
import SnapshotTesting
import XCTest

@MainActor
final class SharedControlSnapshots: XCTestCase {
    func testCompressedTabTitles() throws {
        let longTitles = (1...5).map { "Session\($0) research notes" }
        let sessions = ["Session1", "Session27", "Session30", "Session9", "Session25", "Session28", "Session31", "Session32"]
        for (width, titles) in [(340, longTitles), (450, longTitles), (780, longTitles), (1050, sessions)] {
            let controller = BonsplitController(configuration: .init(
                allowSplits: false,
                appearance: .init(showSplitButtons: false, enableAnimations: false)
            ))
            for id in controller.allTabIds { _ = controller.closeTab(id) }
            for title in titles {
                _ = controller.createTab(title: title, icon: "globe")
            }
            let strip = BonsplitTabBar(controller: controller, createTab: {})
                .frame(width: CGFloat(width), height: BonsplitTabStyle.barHeight)
            try snapshot(strip, name: "compressed-tab-titles-\(width)",
                         size: .init(width: width, height: 50))
        }
    }

    func testResponseUsageFooter() throws {
        let call = ChatUsageCall(reported: true, inputTokens: 12_000, outputTokens: 340, totalTokens: 12_340, cachedInputTokens: 8_000)
        let partial = ChatUsageCall(reported: false, inputTokens: 100, outputTokens: 0, totalTokens: 100)
        for width in [260, 620] {
            let view = VStack(alignment: .leading, spacing: 24) {
                ChatAssistantMessage(copy: { true }) { Text("The requested work is complete.") }
                ChatResponseUsageFooter(summary: .init(usage: ChatUsage(calls: [call]), modelName: "Fixture", costUSD: 0.0123, costSource: "rel.me"))
                ChatResponseUsageFooter(summary: .init(usage: ChatUsage(calls: [call]), modelName: "Local", costUSD: 0, costSource: "local"))
                ChatResponseUsageFooter(summary: .init(usage: ChatUsage(calls: [call]), modelName: "Provider", costUSD: 0.00002, costSource: "provider"))
                ChatErrorMessage(content: "The provider is unavailable.")
                ChatResponseUsageFooter(summary: .init(usage: ChatUsage(), modelName: "Unknown", costUSD: nil, costSource: nil))
                ChatStatusMessage(content: "Response interrupted")
                ChatResponseUsageFooter(summary: .init(usage: ChatUsage(calls: [partial]), modelName: "Partial", costUSD: nil, costSource: nil))
            }.padding(16)
            try snapshot(view, name: "response-usage-\(width)", size: .init(width: width, height: 640))
        }
    }

    private let providers: [PickerProvider] = [
        .init(id: "fritz", displayName: "Fritz", groupID: "fritz"),
        .init(id: "amazon-bedrock", displayName: "Bedrock", groupID: "openai-compatible"),
        .init(id: "openai-compatible", displayName: "OpenAI-compatible", groupID: "openai-compatible"),
        .init(id: "anthropic", displayName: "Anthropic", groupID: "anthropic"),
        .init(id: "gemini", displayName: "Google", groupID: "gemini"),
        .init(id: "openai", displayName: "OpenAI", groupID: "openai"),
    ]

    private var models: [ModelPickerItem<String>] {
        providers.map { provider in
            .init(id: provider.id, value: provider.id, displayName: "\(provider.displayName) Model",
                  modelID: "model-\(provider.id)", provider: provider,
                  sourceName: provider.id == "amazon-bedrock" ? "Team account" : nil,
                  badge: provider.id == "openai-compatible" ? .init(systemImage: "wrench.and.screwdriver",
                    help: "Tool compatible", accessibilityLabel: "Tool compatible") : nil)
        }
    }

    func testChatTranscript() throws {
        let view = VStack(alignment: .leading, spacing: 20) {
            ChatUserMessage(content: "Summarize the selected notes.")
            ChatAssistantMessage(copy: { true },
                                 usage: .init(usage: ChatUsage(), modelName: "Fixture", costUSD: nil, costSource: nil)) {
                Text("The notes cover three upcoming milestones.")
            }
            ChatCompletedWorkDisclosure(summary: "Worked for 2 seconds", hasActivities: false) {
                EmptyView()
            }
            ChatActivityRow(activities: [
                .init(id: "1", title: "Read notes", detail: "notes.txt", status: .completed),
                .init(id: "2", title: "Compare dates", status: .running),
                .init(id: "3", title: "Check attachment", status: .failed),
                .init(id: "4", title: "Save summary", status: .interrupted)
            ], showsHeading: false) { _ in EmptyView() }
            ChatErrorMessage(content: "The provider is unavailable. Try again.")
            ChatStatusMessage(content: "Response interrupted")
        }.padding(24)
        try snapshot(view, name: "chat-transcript", size: .init(width: 620, height: 570))
    }

    func testModelPickerPopulated() throws {
        try snapshot(modelPicker(models: Array(models.prefix(3)), recent: [models[0], models[1]]),
                     name: "model-populated", size: .init(width: 440, height: 380))
    }

    func testModelPickerWrappedProviders() throws {
        try snapshot(modelPicker(models: models), name: "model-wrapped",
                     size: .init(width: 440, height: 380))
    }

    func testModelPickerSearch() throws {
        try snapshot(modelPicker(models: models, query: "Team account"), name: "model-search",
                     size: .init(width: 440, height: 380))
    }

    func testModelPickerEmpty() throws {
        try snapshot(modelPicker(models: []), name: "model-empty", size: .init(width: 440, height: 380))
    }

    func testModelPickerNoResults() throws {
        try snapshot(modelPicker(models: models, query: "missing"), name: "model-no-results",
                     size: .init(width: 440, height: 380))
    }

    func testModelProvidersList() throws {
        let view = VStack(spacing: 0) {
            ModelManagementHeader("Models", background: Color(nsColor: .windowBackgroundColor)) {
                Button("Add Provider", systemImage: "plus") {}
            }
            ModelProvidersTable(providers: [
                .init(id: "openai", name: "OpenAI", warning: nil, isLocal: false,
                      isDefault: true, models: "Example Flagship, Example Fast, Example Mini, Example Nano, Example Audio, Example Embedding"),
                .init(id: "local", name: "Local", warning: "Download a model", isLocal: true,
                      isDefault: false, models: "Local Model")
            ], selection: .constant([]), isLoading: false) { _ in }
            .scrollContentBackground(.hidden)
            .alternatingRowBackgrounds(.disabled)
        }
        try snapshot(view, name: "model-providers-list", size: .init(width: 760, height: 300))
        try snapshot(view, name: "model-providers-list-compact", size: .init(width: 520, height: 300))
    }

    func testLocalModelSessionsList() throws {
        let sessions: [LocalModelSessionItem<String>] = [
            .init(id: "available", modelID: "qwen-small", modelName: "Qwen Small",
                  scope: "", processID: nil, isRunning: false, isResponding: false,
                  canStart: false, status: "Available", errorMessage: nil, showsControls: false),
            .init(id: "running", modelID: "qwen-large", modelName: "Qwen Large",
                  scope: "Research chat", processID: 4231, isRunning: true, isResponding: false,
                  canStart: true, status: "Ready", errorMessage: nil),
            .init(id: "failed", modelID: "qwen-code", modelName: "Qwen Code",
                  scope: "Writing chat", processID: nil, isRunning: false, isResponding: false,
                  canStart: true, status: "Failed", errorMessage: "Model could not load")
        ]
        try snapshot(LocalModelSessionsList(sessions: sessions, start: { _ in },
                                            stop: { _ in }, restart: { _ in }),
                     name: "local-model-sessions-list", size: .init(width: 760, height: 320))
    }

    func testUnifiedModelsEditor() throws {
        let store = ModelsFixture(state: "populated")
        // Resolve fixture identities at runtime instead of caching enum case positions.
        for providerID in ["openai", "ollama", "fritz", "jev", "ollaya"] {
            let provider = try XCTUnwrap(AIProviderKind(rawValue: providerID))
            let connection = store.connection(provider)
            try snapshot(ModelsProviderEditor(store: store, localModels: RuntimeFixture(), existing: connection),
                         name: "models-editor-\(provider.rawValue)", size: .init(width: 600, height: 560), settleDuration: 0.45)
        }
        try snapshot(ModelsProviderEditor(store: store, localModels: RuntimeFixture(), existing: nil),
                     name: "models-editor-new", size: .init(width: 600, height: 560), settleDuration: 0.45)
        let availableStore = ModelsFixture(state: "available")
        let localProvider = try XCTUnwrap(AIProviderKind(rawValue: "fritz"))
        try snapshot(ModelsProviderEditor(store: availableStore, localModels: RuntimeFixture(installed: false),
                                          existing: availableStore.connection(localProvider)),
                     name: "models-editor-fritz-available", size: .init(width: 600, height: 560), settleDuration: 0.45)
    }

    func testModelSetupDialogs() throws {
        for (state, provider) in [("available", AIProviderKind.fritz), ("populated", .fritz), ("empty", .anthropic)] {
            let store = ModelsFixture(state: state)
            let model = ChatModelOption(id: "choice", displayName: provider == .fritz ? "Qwen2.5 1.5B" : "Claude",
                                        provider: provider, modelID: provider == .fritz ? "qwen2.5-1.5b-instruct-q4_k_m" : "claude-fixture")
            try snapshot(ModelsProviderEditor(store: store, localModels: RuntimeFixture(installed: state != "available"),
                                              existing: nil, initialModel: model),
                         name: "model-setup-\(provider.rawValue)-\(state)",
                         size: provider == .fritz ? .init(width: 520, height: 240) : .init(width: 600, height: 560), settleDuration: 0.45)
        }
    }

    func testBackgroundDownloadSurvivesClosingAndCanStopAndRetry() async throws {
        let store = ModelsFixture(state: "controlled")
        var firstView: ConfigurationNativeModel? = ConfigurationNativeModel(store: store)
        weak var releasedView = firstView
        let requestID = try XCTUnwrap(firstView?.install())
        firstView = nil
        XCTAssertNil(releasedView)

        let model = ConfigurationNativeModel(store: store)
        defer { model.stopDownload() }
        model.refresh()
        XCTAssertTrue(model.isDownloading)
        XCTAssertNil(model.install())
        let progressDeadline = ContinuousClock.now + .seconds(2)
        while model.state == .checking && ContinuousClock.now < progressDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.state, .downloading(downloaded: 25, total: 100))
        model.stopDownload()
        XCTAssertFalse(model.isDownloading)
        XCTAssertEqual(store.stoppedDownloads, [requestID])

        let retryID = try XCTUnwrap(model.install())
        XCTAssertNotEqual(requestID, retryID)
        try store.finishDownload(retryID)
        let deadline = ContinuousClock.now + .seconds(2)
        while model.installedURL == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.state, .installed)
        XCTAssertEqual(model.installedURL?.path, "/Models/Test.gguf")
    }

    func testUnifiedModelDownload() throws {
        for state in ["available", "installed", "error"] {
            try snapshot(ModelsDownloadSheet(store: ModelsFixture(state: state),
                                            hardware: LocalModelHardware(memoryGB: 32, appleSilicon: true)),
                         name: "models-download-\(state)", size: .init(width: 840, height: 540), settleDuration: 0.45)
        }
    }

    private func modelPicker(models: [ModelPickerItem<String>], recent: [ModelPickerItem<String>] = [],
                             query: String = "") -> some View {
        ModelPickerPopover(models: models, recentModels: recent,
                           modelProviders: providers.map(\.groupID), selectedModelID: "fritz",
                           selectModel: { _ in }, configureModels: {}, initialSearchText: query,
                           supportedProviders: PickerProvider.chatProviders)
    }

    private var categories: [PickerCategory] {
        [.all, .init(id: "system1", title: "System1", help: "Decision models"),
         .init(id: "local", title: "Local", help: "Local providers"),
         .init(id: "remote", title: "Remote", help: "Remote providers"),
         .init(id: "frontier", title: "Frontier", help: "Frontier providers"),
         .init(id: "hosted", title: "Hosted", help: "Hosted providers"),
         .init(id: "custom", title: "Custom", help: "Custom endpoints")]
    }

    private var providerItems: [ProviderPickerItem<String>] {
        providers.map { provider in
            .init(id: provider.id, value: provider.id, name: provider.displayName,
                  categoryIDs: [provider.id == "fritz" ? "local" : "remote"],
                  badgeText: provider.id == "fritz" ? "local" : nil)
        }
    }

    func testProviderPickerControl() throws {
        let view = VStack(spacing: 16) {
            ProviderPicker(selection: providerItems[0], providers: providerItems,
                           categories: categories, onSelect: { _ in })
            ProviderPicker(selection: providerItems[1], providers: providerItems,
                           categories: categories, onSelect: { _ in }).disabled(true)
        }.padding(20)
        try snapshot(view, name: "provider-control", size: .init(width: 440, height: 120))
    }

    func testProviderPickerPopulated() throws {
        try snapshot(providerPicker(), name: "provider-populated", size: .init(width: 500, height: 420))
    }

    func testProviderPickerCategory() throws {
        try snapshot(providerPicker(category: "local"), name: "provider-local",
                     size: .init(width: 500, height: 420))
    }

    func testProviderPickerSearch() throws {
        try snapshot(providerPicker(query: "Bedrock"), name: "provider-search",
                     size: .init(width: 500, height: 420))
    }

    func testProviderPickerNoResults() throws {
        try snapshot(providerPicker(query: "missing"), name: "provider-no-results",
                     size: .init(width: 500, height: 420))
    }

    private func providerPicker(category: String = "all", query: String = "") -> some View {
        ProviderPickerContent(selection: providerItems[0], initialSearchText: query,
                              categories: categories, initialCategoryID: category,
                              providers: providerItems, onSelect: { _ in })
    }

    // Liquid Glass requires WindowServer compositing and produces transparent
    // readbacks here. Keep floating styles in the documented native UI checks.
    func testButtonStyles() throws {
        let styles: [(String, FritzButtonStyle.Context)] = [
            ("Content", .content), ("Primary", .primary), ("Inline", .inline),
            ("Link", .link), ("Panel", .panel), ("Toolbar", .toolbar),
        ]
        let view = VStack(spacing: 14) {
            ForEach(styles.indices, id: \.self) { index in
                HStack {
                    Text(styles[index].0).frame(width: 135, alignment: .leading)
                    Button("Action") {}.buttonStyle(FritzButtonStyle(styles[index].1))
                    Button("Disabled") {}.buttonStyle(FritzButtonStyle(styles[index].1)).disabled(true)
                }
            }
            HStack {
                Button("Compact") {}.buttonStyle(FritzButtonStyle()).fritzButtonSize(.small)
                Button("Delete", role: .destructive) {}.buttonStyle(FritzButtonStyle())
                Button("Refresh", systemImage: "arrow.clockwise") {}.modifier(FritzPanelIconControl())
            }
        }.padding(20)
        try snapshot(view, name: "button-styles", size: .init(width: 460, height: 450))
    }

    private func snapshot<V: View>(_ view: V, name: String, size: CGSize,
                                   settleDuration: TimeInterval = 0.15, file: StaticString = #filePath, line: UInt = #line) throws {
        let mode = ProcessInfo.processInfo.environment["FRITZ_SNAPSHOT_MODE"]
        guard mode == "compare" || mode == "record" else {
            throw XCTSkip("Run make check-ui-snapshots to compare visual references.")
        }
        let recordPrefix = ProcessInfo.processInfo.environment["FRITZ_SNAPSHOT_RECORD_PREFIX"]
        let recordsSnapshot = mode == "record" && (recordPrefix.map { name.hasPrefix($0) } ?? true)
        for scheme in [ColorScheme.light, .dark] {
            let appearance = scheme == .dark ? "dark" : "light"
            let reference = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
                .appendingPathComponent("__Snapshots__/SharedControlSnapshots/\(name)-macOS.\(appearance).png")
            if !recordsSnapshot, !FileManager.default.fileExists(atPath: reference.path) {
                XCTFail("Missing reviewed reference: \(reference.path)", file: file, line: line)
                continue
            }
            let image = try renderSettled(
                view
                    .frame(width: size.width, height: size.height)
                    .background(scheme == .dark ? Color(nsColor: .darkGray) : .white)
                    .environment(\.colorScheme, scheme)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .environment(\.controlActiveState, .key)
                    // Suppress indicators before initial layout so a legacy
                    // scrollbar preference cannot reserve document width.
                    .scrollIndicators(.never)
                    .tint(.blue), appearance: scheme == .dark ? .darkAqua : .aqua, size: size, settleDuration: settleDuration)
            // Compare the fixed 2x bitmap directly. Hosting it in another view
            // would resample it at the attached display's backing scale.
            SnapshotTesting.assertSnapshot(
                of: image, as: .image, named: appearance,
                record: recordsSnapshot, file: file, testName: "\(name)-macOS", line: line)
        }
    }

    private func renderSettled<V: View>(_ view: V, appearance name: NSAppearance.Name,
                                       size: CGSize, settleDuration: TimeInterval) throws -> NSImage {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        let app = NSApplication.shared
        let previous = app.appearance
        app.appearance = appearance
        defer { app.appearance = previous }
        let bounds = NSRect(origin: .zero, size: size)
        let host = NSHostingView(rootView: view)
        host.frame = bounds
        host.appearance = appearance
        host.wantsLayer = true
        host.layer?.contentsScale = 2
        let window = SnapshotWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.colorSpace = .sRGB
        // Native table headers composite against the window, not only the host.
        // Match the fixture backdrop instead of inheriting the desktop appearance.
        window.backgroundColor = appearance.name == .darkAqua ? .darkGray : .white
        window.appearance = appearance
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: settleDuration))
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        // SwiftUI hides the scroller but legacy AppKit style still reserves a
        // 17-point gutter. Pin the fixture instead of inheriting macOS settings.
        func normalizeScrollers(in view: NSView) {
            if let scrollView = view as? NSScrollView {
                // Re-layout even when the inherited style already reports overlay.
                scrollView.scrollerStyle = .legacy
                scrollView.scrollerStyle = .overlay
                scrollView.tile()
            }
            view.subviews.forEach { normalizeScrollers(in: $0) }
        }
        normalizeScrollers(in: host)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        host.layoutSubtreeIfNeeded()
        // Native table autosizing can leave the final column half a point
        // narrower depending on earlier AppKit initialization. Round columns
        // consistently so header dividers do not vary by one backing pixel.
        func normalizeColumns(in view: NSView) {
            if let table = view as? NSTableView {
                for column in table.tableColumns {
                    column.width = column.width.rounded(.up)
                }
                table.headerView?.needsDisplay = true
            }
            view.subviews.forEach { normalizeColumns(in: $0) }
        }
        normalizeColumns(in: host)
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: Int(size.width * 2) * 4, bitsPerPixel: 32))
        bitmap.size = size
        host.cacheDisplay(in: bounds, to: bitmap)
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

}

// AppKit and SwiftUI must rasterize at the same scale as the snapshot bitmap,
// including on CI displays whose native backing scale is 1x.
@MainActor private final class SnapshotWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 2 }
}

@MainActor @Observable private final class ModelsFixture: ModelsProviderStore {
    let modelDownloads = ModelDownloads()
    let modelStorage = ModelStorage(events: { _, _, _ in
        AsyncThrowingStream { continuation in
            continuation.yield(Data(#"{"type":"result","result":{"directory":"/Models","modelCount":0,"bytes":0}}"#.utf8))
            continuation.finish()
        }
    }, cancel: { _ in })
    let state: String
    var error: String?
    var isLoading: Bool { state == "loading" }
    var connections: [ProviderConnection] { ["empty", "loading"].contains(state) ? [] : [.init(id: connectionID, name: "Test", provider: .ollama)] }
    var defaultConnectionID: UUID? { connections.first?.id }
    var catalog: [UUID: [DiscoveredAIModel]] { [connectionID: [.init(id: "test-model", displayName: "Test Model")]] }
    var discoveryErrors: [UUID: String] { state == "error" ? [connectionID: "The provider is unavailable."] : [:] }
    var recentIDs: [String] { [] }
    var nativeModelCatalog: [NativeModelDescriptor] { NativeModelDescriptor.catalog + NativeModelDescriptor.decisionCatalog }
    private let connectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private var downloadedIDs: Set<String> = []
    private var pendingDownloads: [String: (String, AsyncThrowingStream<Data, Error>.Continuation)] = [:]
    private(set) var stoppedDownloads: [String] = []
    init(state: String) { self.state = state; error = state == "error" ? "The provider is unavailable." : nil }
    func connection(_ provider: AIProviderKind) -> ProviderConnection {
        .init(id: connectionID, name: "Test", provider: provider,
              modelID: provider.rawValue == "ollaya" ? NativeModelDescriptor.decisionCatalog[0].id : "qwen2.5-1.5b-instruct-q4_k_m")
    }
    func refresh() async {}
    func save(_ connection: ProviderConnection, key: String, makeDefault: Bool) async throws {}
    func remove(_ connection: ProviderConnection) async {}
    func makeDefault(_ connection: ProviderConnection) async {}
    func importProviders(_ text: String, policy: ModelsImportPolicy) async throws {}
    func exportProviders(_ connections: [ProviderConnection], includeKeys: Bool) throws -> String { "" }
    func discoverModels(_ connection: ProviderConnection, key: String) async throws -> [DiscoveredAIModel] {
        [.init(id: "test-model", displayName: "Test Model")]
    }
    func modelEvents(category: AIModelCategory, modelID: String, install: Bool, directory: URL?,
                     requestID: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            if state == "error" { continuation.finish(throwing: AgentFailure(message: "The installer is unavailable.")); return }
            if install && state == "controlled" {
                pendingDownloads[requestID] = (modelID, continuation)
                continuation.yield(Data(#"{"type":"progress","status":"downloading","downloaded":25,"total":100}"#.utf8))
                return
            }
            let result: [String: Any]
            if install {
                downloadedIDs.insert(modelID)
                result = ["modelId": modelID, "installed": true]
            } else {
                result = ["models": [
                    ["id": modelID, "installed": state == "installed" || state == "populated" || downloadedIDs.contains(modelID),
                     "path": "/Models/Test.gguf", "directory": directory?.path ?? "/Models"]
                ]]
            }
            let event: [String: Any] = ["type": "result", "result": result]
            continuation.yield(try! JSONSerialization.data(withJSONObject: event)); continuation.finish()
        }
    }
    func cancelModelRequest(_ requestID: String) {
        guard let (_, pending) = pendingDownloads.removeValue(forKey: requestID) else { return }
        stoppedDownloads.append(requestID)
        pending.finish(throwing: CancellationError())
    }

    func finishDownload(_ requestID: String) throws {
        let (modelID, pending) = try XCTUnwrap(pendingDownloads.removeValue(forKey: requestID))
        downloadedIDs.insert(modelID)
        pending.yield(try JSONSerialization.data(withJSONObject: [
            "type": "result", "result": ["modelId": modelID, "installed": true],
        ]))
        pending.finish()
    }
}

@MainActor @Observable private final class RuntimeFixture: ModelsRuntimeStore {
    private let installed: Bool
    init(installed: Bool = true) { self.installed = installed }
    var installedIDs: Set<String> { installed ? ["qwen2.5-1.5b-instruct-q4_k_m"] : [] }
    var sessions: [String: ModelsRuntimeSession] { installed ? ["qwen2.5-1.5b-instruct-q4_k_m": .init(status: .running, processID: 1234)] : [:] }
    var service: ModelsRuntimeSession { .init(status: .running, address: "http://127.0.0.1:11435") }
    var isLoading: Bool { false }
    var error: String? { nil }
    var policyError: String? { nil }
    func policy(for modelID: String) -> ModelsStartPolicy { .firstUse }
    func setPolicy(_ policy: ModelsStartPolicy, for modelID: String) throws {}
    func refresh() async {}
    func start(_ modelID: String) {}
    func stop(_ modelID: String) {}
}

extension SharedControlSnapshots {
    func testAttachedModelDownloadStates() async throws {
        try DialogSnapshot.requireEnabled()
        let model = NativeModelDescriptor(id: "fixture", name: "Qwen3.5 9B", size: 5_680_000_000,
                                          memoryGB: 16, licenseURL: URL(string: "https://example.com/license")!)
        for appearance in DialogSnapshot.appearances {
            let fixture = DownloadSheetFixture(model: model)
            try await DialogSnapshot.withSheet(fixture, appearance: appearance) { sheet in
                let initial = try await DialogSnapshot.check(sheet, name: "model-download-ready", appearance: appearance)
                fixture.progress.state = .downloading(
                    downloaded: 529_200_000, total: model.size, bytesPerSecond: 22_600_000
                )
                let downloading = try await DialogSnapshot.check(sheet, name: "model-download-progress", appearance: appearance)
                XCTAssertGreaterThan(downloading.height, initial.height)
                XCTAssertEqual(downloading.width, initial.width)

                fixture.progress.state = .failed("The connection closed unexpectedly. Check your connection and retry the download. Fritz will resume from the last saved byte.")
                try await DialogSnapshot.check(sheet, name: "model-download-error", appearance: appearance)

                fixture.progress.state = .installed
                let installed = try await DialogSnapshot.check(sheet, name: "model-download-installed", appearance: appearance)
                XCTAssertLessThan(installed.height, downloading.height)
            }
        }
    }
}

@MainActor private struct DownloadSheetFixture: View {
    @Observable final class Progress {
        var state = LocalModelInstallState.available
    }

    let progress = Progress()
    let model: NativeModelDescriptor
    let storage = ModelsFixture(state: "available").modelStorage

    var body: some View {
        LocalModelSetupSheet(model: model, state: progress.state, memoryGB: 8, storage: storage,
                             installedDirectory: URL(fileURLWithPath: "/Models"),
                             primaryActionTitle: actionTitle, canSubmit: !progress.state.isBusy,
                             isSaving: false, isDownloading: progress.state.isBusy,
                             close: {}, stopDownload: {}, submit: {}) { EmptyView() }
    }

    private var actionTitle: String {
        switch progress.state {
        case .installed: "Use Model"
        case .failed: "Retry Download"
        default: "Download"
        }
    }
}

extension SharedControlSnapshots {
    func testAttachedModelTransferDialogs() async throws {
        try DialogSnapshot.requireEnabled()
        let store = ModelsFixture(state: "empty")
        let request = "curl https://models.example.com/v1/models"
        for appearance in DialogSnapshot.appearances {
            try await DialogSnapshot.withSheet(ConfigurationTransferSheet(store: store), appearance: appearance) { sheet in
                try await DialogSnapshot.check(sheet, name: "model-import-empty", appearance: appearance)
            }
            for includesKeys in [false, true] {
                let key = includesKeys ? "EXAMPLE_KEY" : "YOUR_API_KEY"
                let export = ProviderTextExport(text: "\(request) \\\n  -H 'Authorization: Bearer \(key)'", includesKeys: includesKeys)
                let name = includesKeys ? "model-export-with-keys" : "model-export-without-keys"
                try await DialogSnapshot.withSheet(ConfigurationTransferSheet(store: store, exported: export),
                                                    appearance: appearance) { sheet in
                    try await DialogSnapshot.check(sheet, name: name, appearance: appearance)
                }
            }
        }
    }

    func testAttachedProviderModelsDialog() async throws {
        try DialogSnapshot.requireEnabled()
        let id = UUID()
        let models = [DiscoveredAIModel(id: "sample-recent", displayName: "Sample Recent"),
                      DiscoveredAIModel(id: "sample-other", displayName: "Sample Other")]
        for appearance in DialogSnapshot.appearances {
            let content = ProviderModelsSheet(models: models, recentModelIDs: ["connection:\(id.uuidString):sample-recent"],
                                              connectionID: id)
            try await DialogSnapshot.withSheet(content, appearance: appearance) { sheet in
                try await DialogSnapshot.check(sheet, name: "provider-models-recent", appearance: appearance)
            }
        }
    }

    func testAttachedModelStorageMoveDialog() async throws {
        try DialogSnapshot.requireEnabled()
        for appearance in DialogSnapshot.appearances {
            let (events, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            let storage = ModelStorage(events: { _, _, _ in events }, cancel: { _ in })
            let move = Task { await storage.change(to: URL(fileURLWithPath: "/New Models"),
                                                  previous: "/Models", moveModels: true) }
            defer { move.cancel(); continuation.finish() }
            try await DialogSnapshot.withSheet(ModelStorageMoveSheet(storage: storage, cancel: {}),
                                               appearance: appearance) { sheet in
                try await DialogSnapshot.check(sheet, name: "model-storage-move-start", appearance: appearance)
                continuation.yield(Data(#"{"type":"progress","completed":2100000000,"total":5000000000,"file":"Qwen3.5-9B-with-a-long-model-filename-Q4_K_M.gguf"}"#.utf8))
                try await DialogSnapshot.check(sheet, name: "model-storage-move-progress", appearance: appearance)
            }
        }
    }
}
