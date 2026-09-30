import AppKit
import ScreenCaptureKit

// Capture only the launched app's native window, never the desktop or another app.
@main struct CaptureWindow {
    @MainActor static func main() async {
        do { try await capture() }
        catch {
            FileHandle.standardError.write(Data("Capture failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor static func capture() async throws {
        _ = NSApplication.shared
        let args = CommandLine.arguments
        guard args.count >= 3 else { throw failure("Expected pid|quit|capture APP [OUTPUT]") }
        let appURL = URL(fileURLWithPath: args[2]).resolvingSymlinksInPath()
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.resolvingSymlinksInPath() == appURL
        }
        if args[1] == "pid" {
            guard apps.count <= 1 else { throw failure("Multiple instances of the capture app are running.") }
            print(apps.first?.processIdentifier ?? 0)
            return
        }
        guard apps.count == 1, let app = apps.first else { throw failure("Capture app is not running.") }
        if args[1] == "quit" {
            guard app.terminate() else { throw failure("Could not quit the capture app.") }
            return
        }
        guard args[1] == "capture", args.count == 4 else { throw failure("Expected capture APP OUTPUT") }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = content.windows.filter {
            $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0
                && $0.frame.width >= 900 && $0.frame.height >= 620
        }
        guard windows.count == 1, let window = windows.first else {
            throw failure("Expected exactly one visible Fritz chat window; close other app windows.")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * 2)
        configuration.height = Int(window.frame.height * 2)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.shouldBeOpaque = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw failure("Could not encode the captured window.")
        }
        try png.write(to: URL(fileURLWithPath: args[3]), options: .atomic)
        print("Captured \(image.width) × \(image.height): \(args[3])")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "FritzWebsiteCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
