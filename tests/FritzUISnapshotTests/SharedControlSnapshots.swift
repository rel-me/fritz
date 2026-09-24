import AppKit
import FritzUI
import SwiftUI
import SwiftUISnapshotTesting
import XCTest

@MainActor
final class SharedControlSnapshots: XCTestCase {
    private let providers: [PickerProvider] = [
        .init(id: "fritz", displayName: "Fritz", groupID: "local"),
        .init(id: "bedrock", displayName: "Bedrock", groupID: "compatible"),
        .init(id: "gateway", displayName: "OpenAI-compatible", groupID: "compatible"),
        .init(id: "anthropic", displayName: "Anthropic", groupID: "anthropic"),
        .init(id: "google", displayName: "Google Gemini", groupID: "google"),
        .init(id: "openai", displayName: "OpenAI", groupID: "openai"),
    ]

    private var models: [ModelPickerItem<String>] {
        providers.map { provider in
            .init(id: provider.id, value: provider.id, displayName: "\(provider.displayName) Model",
                  modelID: "model-\(provider.id)", provider: provider,
                  sourceName: provider.id == "bedrock" ? "Team account" : nil,
                  badge: provider.id == "gateway" ? .init(systemImage: "wrench.and.screwdriver",
                    help: "Tool compatible", accessibilityLabel: "Tool compatible") : nil)
        }
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

    private func modelPicker(models: [ModelPickerItem<String>], recent: [ModelPickerItem<String>] = [],
                             query: String = "") -> some View {
        ModelPickerPopover(models: models, recentModels: recent,
                           modelProviders: providers.map(\.groupID), selectedModelID: "fritz",
                           selectModel: { _ in }, configureModels: {}, initialSearchText: query)
    }

    private var categories: [PickerCategory] {
        [.all, .init(id: "local", title: "Local", help: "Local providers"),
         .init(id: "remote", title: "Remote", help: "Remote providers")]
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
        try snapshot(providerPicker(), name: "provider-populated", size: .init(width: 440, height: 420))
    }

    func testProviderPickerCategory() throws {
        try snapshot(providerPicker(category: "local"), name: "provider-local",
                     size: .init(width: 440, height: 420))
    }

    func testProviderPickerSearch() throws {
        try snapshot(providerPicker(query: "Bedrock"), name: "provider-search",
                     size: .init(width: 440, height: 420))
    }

    func testProviderPickerNoResults() throws {
        try snapshot(providerPicker(query: "missing"), name: "provider-no-results",
                     size: .init(width: 440, height: 420))
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
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let mode = ProcessInfo.processInfo.environment["FRITZ_SNAPSHOT_MODE"]
        guard mode == "compare" || mode == "record" else {
            throw XCTSkip("Run make check-ui-snapshots to compare visual references.")
        }
        for scheme in [ColorScheme.light, .dark] {
            let appearance = scheme == .dark ? "dark" : "light"
            let reference = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
                .appendingPathComponent("__Snapshots__/SharedControlSnapshots/\(name)-macOS.\(appearance).png")
            if mode == "compare", !FileManager.default.fileExists(atPath: reference.path) {
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
                    .scrollIndicators(.hidden)
                    .tint(.blue), appearance: scheme == .dark ? .darkAqua : .aqua, size: size)
            // The package compares the fully rendered native surface. Its detached
            // host forces light AppKit appearance and does not settle native controls.
            SwiftUISnapshotTesting.assertSnapshot(
                view: Image(nsImage: image).resizable().interpolation(.none),
                device: .macOS(width: size.width, height: size.height), named: appearance,
                record: mode == "record", file: file, testName: name, line: line)
        }
    }

    private func renderSettled<V: View>(_ view: V, appearance name: NSAppearance.Name,
                                       size: CGSize) throws -> NSImage {
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
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.colorSpace = .sRGB
        window.appearance = appearance
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        // SwiftUI hides the scroller but legacy AppKit style still reserves a
        // 17-point gutter. Pin the fixture instead of inheriting macOS settings.
        func normalizeScrollers(in view: NSView) {
            if let scrollView = view as? NSScrollView {
                scrollView.scrollerStyle = .overlay
            }
            view.subviews.forEach { normalizeScrollers(in: $0) }
        }
        normalizeScrollers(in: host)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        host.layoutSubtreeIfNeeded()
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
