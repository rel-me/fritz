import SwiftUI

/// REL's native window palette and inset surfaces, independent of its runtime.
enum FritzWindowStyle {
    static let cornerRadius: CGFloat = 20
    static let workspaceBackgroundNSColor = adaptive(light: 0xebebeb, dark: 0x181818)
    static let contentBackgroundNSColor = adaptive(light: 0xf7f7f7, dark: 0x262626)
    static let workspaceBackground = Color(nsColor: workspaceBackgroundNSColor)
    static let contentBackground = Color(nsColor: contentBackgroundNSColor)

    private static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
    }
}

/// Match the native fullscreen toolbar while retaining Fritz's windowed palette.
/// AppKit owns the window mode; this background redraws without publishing view state.
struct FritzWorkspaceBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> BackgroundView { BackgroundView() }
    func updateNSView(_ nsView: BackgroundView, context: Context) {}

    static func dismantleNSView(_ nsView: BackgroundView, coordinator: ()) {
        NotificationCenter.default.removeObserver(nsView)
    }

    final class BackgroundView: NSView {
        override var isOpaque: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(redraw),
                                                           name: name, object: window)
                }
            }
            needsDisplay = true
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        @objc private func redraw(_ notification: Notification) {
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let color = window?.styleMask.contains(.fullScreen) == true
                ? NSColor.windowBackgroundColor
                : FritzWindowStyle.workspaceBackgroundNSColor
            color.setFill()
            bounds.fill()
        }
    }
}

struct WindowNewItemMenu: View {
    let canCreateThread: Bool
    let createProject: () -> Void
    let createThread: () -> Void
    let createProvider: () -> Void

    var body: some View {
        Menu {
            Button("New Project", action: createProject)
            Button("New Thread", action: createThread).disabled(!canCreateThread)
            Divider()
            Button("New Provider", action: createProvider)
        } label: {
            Label("New", systemImage: "plus")
        }
        .labelStyle(.iconOnly)
        .menuIndicator(.hidden)
        .buttonStyle(FritzButtonStyle(.toolbar))
        .help("New")
        .accessibilityIdentifier("window-new-item-menu")
    }
}
