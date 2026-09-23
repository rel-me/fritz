import SwiftUI

/// Shared palette and inset surfaces for every Fritz window.
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

// Keep scene chrome and root backgrounds paired on every app-owned window.
extension Scene {
    func fritzWindowStyle() -> some Scene {
        windowToolbarStyle(.unified(showsTitle: false))
    }
}

extension View {
    func fritzWindowBackground() -> some View {
        background(FritzWindowStyle.workspaceBackground)
            .background(FritzWindowChrome())
            .toolbarBackground(FritzWindowStyle.workspaceBackground, for: .windowToolbar)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
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
