import Bonsplit
import SwiftUI

/// Shared palette and inset surfaces for every Fritz window.
public enum ModelsConfigurationStyle {
    public static let cornerRadius: CGFloat = 20
    public static let workspaceBackgroundNSColor = NSColor(name: nil) { appearance in
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
    public static let chatInputBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 69.0 / 255.0, green: 69.0 / 255.0,
                      blue: 69.0 / 255.0, alpha: 1)
            : BonsplitTabStyle.stripBackground
    })
    public static let contentBackgroundNSColor = BonsplitTabStyle.selectedBackground
    public static let workspaceBackground = Color(nsColor: workspaceBackgroundNSColor)
    public static let contentBackground = Color(nsColor: contentBackgroundNSColor)
}
