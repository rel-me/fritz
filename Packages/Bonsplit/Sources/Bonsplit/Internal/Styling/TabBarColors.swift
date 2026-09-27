import SwiftUI
import AppKit

/// Native macOS colors for the tab bar
enum TabBarColors {
    // MARK: - Tab Bar Background

    static func barBackground(for appearance: BonsplitConfiguration.Appearance) -> Color {
        appearance.tabBarBackground ?? Color(nsColor: BonsplitTabStyle.stripBackground)
    }

    static var barMaterial: Material {
        .bar
    }

    // MARK: - Tab States

    static func activeTabBackground(for appearance: BonsplitConfiguration.Appearance) -> Color {
        appearance.activeTabBackground ?? Color(nsColor: BonsplitTabStyle.selectedBackground)
    }

    static var hoveredTabBackground: Color {
        Color(nsColor: BonsplitTabStyle.hoverBackground)
    }

    static var inactiveTabBackground: Color {
        .clear
    }

    // MARK: - Text Colors

    static var activeText: Color {
        Color(nsColor: BonsplitTabStyle.foreground)
    }

    static var inactiveText: Color {
        Color(nsColor: BonsplitTabStyle.foreground)
    }

    // MARK: - Borders & Indicators

    static var separator: Color {
        Color(nsColor: BonsplitTabStyle.separator)
    }

    static var dropIndicator: Color {
        Color.accentColor
    }

    static var focusRing: Color {
        Color.accentColor.opacity(0.5)
    }

    static var dirtyIndicator: Color {
        Color(nsColor: BonsplitTabStyle.foreground).opacity(0.6)
    }

    // MARK: - Shadows

    static var tabShadow: Color {
        Color.black.opacity(0.08)
    }
}
