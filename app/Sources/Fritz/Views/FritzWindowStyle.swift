import Bonsplit
import SwiftUI

/// Shared palette and inset surfaces for every Fritz window.
enum FritzWindowStyle {
    static let cornerRadius: CGFloat = 20
    static let workspaceBackgroundNSColor = NSColor(name: nil) { appearance in
        var color = NSColor.textBackgroundColor
        // Resolve nested colors for native window chrome as well as SwiftUI.
        appearance.performAsCurrentDrawingAppearance {
            let background = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? BonsplitTabStyle.stripBackground
                : .textBackgroundColor
            color = background.usingColorSpace(.sRGB) ?? background
        }
        return color
    }
    static let chatInputBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 69.0 / 255.0, green: 69.0 / 255.0,
                      blue: 69.0 / 255.0, alpha: 1)
            : BonsplitTabStyle.stripBackground
    })
    static let contentBackgroundNSColor = BonsplitTabStyle.selectedBackground
    static let workspaceBackground = Color(nsColor: workspaceBackgroundNSColor)
    static let contentBackground = Color(nsColor: contentBackgroundNSColor)
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
    let createLocalModel: () -> Void

    var body: some View {
        Menu {
            Button("New Project", action: createProject)
            Button("New Chat", action: createThread).disabled(!canCreateThread)
            Divider()
            Button("New Model", action: createProvider)
            Button("New Local Model", action: createLocalModel)
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

// Keep scene chrome and root backgrounds paired on every app-owned window.
extension Scene {
    func fritzWindowStyle() -> some Scene {
        windowToolbarStyle(.unified(showsTitle: false))
    }
}

extension View {
    func fritzWindowBackground() -> some View {
        background { FritzWorkspaceBackground().ignoresSafeArea() }
            .background(FritzWindowChrome())
            .toolbarBackground(FritzWindowStyle.workspaceBackground, for: .windowToolbar)
            // Preserve the sidebar’s rounded outline through the titlebar.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            // Keep the workspace palette behind the native fullscreen toolbar.
            .containerBackground(FritzWindowStyle.workspaceBackground, for: .window)
    }
}

/// Settings can retain its preferences toolbar style despite the scene modifier.
/// Configure only the window hosting this root, without searching global windows.
private struct FritzWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowView { WindowView() }

    func updateNSView(_ nsView: WindowView, context: Context) {
        nsView.applyStyle()
    }

    final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyStyle()
        }

        func applyStyle() {
            guard let window else { return }
            if window.toolbarStyle != .unified { window.toolbarStyle = .unified }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        }
    }
}
