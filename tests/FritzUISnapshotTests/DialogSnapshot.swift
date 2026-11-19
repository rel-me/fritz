import AppKit
import SnapshotTesting
import SwiftUI
import XCTest

/// Snapshots the content of a real SwiftUI sheet at its attached window size.
@MainActor
enum DialogSnapshot {
    static let appearances: [ColorScheme] = [.light, .dark]

    static func requireEnabled() throws {
        guard ["compare", "record"].contains(ProcessInfo.processInfo.environment["FRITZ_SNAPSHOT_MODE"]) else {
            throw XCTSkip("Run make check-ui-snapshots to compare visual references.")
        }
    }

    static func withSheet<Dialog: View>(
        _ dialog: Dialog, appearance: ColorScheme,
        perform: (NSWindow) async throws -> Void
    ) async throws {
        try requireEnabled()
        let app = NSApplication.shared
        let priorAppearance = app.appearance
        let nativeAppearance = try XCTUnwrap(NSAppearance(named: appearance == .dark ? .darkAqua : .aqua))
        app.appearance = nativeAppearance
        defer { app.appearance = priorAppearance }

        let parent = FixtureWindow(contentRect: .init(x: -10_000, y: -10_000, width: 900, height: 680),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.animationBehavior = .none
        parent.appearance = nativeAppearance
        parent.colorSpace = .sRGB
        parent.contentView = NSHostingView(rootView:
            Color.clear
                .sheet(isPresented: .constant(true)) {
                    dialog
                        .background { Color(nsColor: .windowBackgroundColor) }
                        .environment(\.colorScheme, appearance)
                        .environment(\.locale, Locale(identifier: "en_US"))
                        .environment(\.controlActiveState, .key)
                        .scrollIndicators(.never)
                        .tint(.blue)
                }
                .transaction { $0.disablesAnimations = true }
        )
        defer {
            if let sheet = parent.attachedSheet { parent.endSheet(sheet) }
            parent.contentView = nil
            parent.close()
        }
        parent.orderBack(nil)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while parent.attachedSheet == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let sheet = try XCTUnwrap(parent.attachedSheet, "SwiftUI did not attach the dialog to its test window.")
        sheet.appearance = nativeAppearance
        sheet.colorSpace = .sRGB
        try await perform(sheet)
    }

    @discardableResult
    static func check(
        _ sheet: NSWindow, name: String, appearance: ColorScheme,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> CGSize {
        let environment = ProcessInfo.processInfo.environment
        let prefix = environment["FRITZ_SNAPSHOT_RECORD_PREFIX"]
        let record = environment["FRITZ_SNAPSHOT_MODE"] == "record" && (prefix.map { name.hasPrefix($0) } ?? true)
        let scheme = appearance == .dark ? "dark" : "light"
        let directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__/DialogSnapshots")
        let reference = directory.appendingPathComponent("\(name).\(scheme).png")
        let image = try await capture(sheet)
        guard record || FileManager.default.fileExists(atPath: reference.path) else {
            XCTFail("Missing reviewed reference: \(reference.path)", file: file, line: line)
            return image.size
        }
        withSnapshotTesting(record: record ? .all : .never) {
            let result = verifySnapshot(of: image, as: .image, named: scheme,
                                        snapshotDirectory: directory.path, testName: name)
            if let result { XCTFail(result, file: file, line: line) }
        }
        return image.size
    }

    private static func capture(_ sheet: NSWindow) async throws -> NSImage {
        let view = try XCTUnwrap(sheet.contentView)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var previous: NSBitmapImageRep?
        while ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(35))
            sheet.layoutIfNeeded()
            view.layoutSubtreeIfNeeded()
            let size = view.bounds.size
            guard size.width > 0, size.height > 0 else { continue }
            let width = Int((size.width * 2).rounded())
            let height = Int((size.height * 2).rounded())
            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .calibratedRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
            bitmap.size = size
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let previous, previous.pixelsWide == width, previous.pixelsHigh == height,
               let previousBytes = previous.bitmapData, let bytes = bitmap.bitmapData,
               memcmp(previousBytes, bytes, bitmap.bytesPerRow * height) == 0 {
                let image = NSImage(size: size)
                image.addRepresentation(bitmap)
                return image
            }
            previous = bitmap
        }
        throw CaptureError.unsettled
    }

    private enum CaptureError: Error { case unsettled }

    private final class FixtureWindow: NSWindow {
        override var backingScaleFactor: CGFloat { 2 }
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
}
