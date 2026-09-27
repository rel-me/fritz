import AppKit
import SwiftUI

/// REL design-system tokens for the production Bonsplit tab strip.
/// The Tabs gallery renders these same views and tokens in both appearances.
public enum BonsplitTabStyle {
    // MARK: - Tab Bar

    public static let barHeight: CGFloat = 42
    public static let barLeadingPadding: CGFloat = 8

    // MARK: - Individual Tabs

    public static let tabHeight: CGFloat = 35
    public static let tabMinWidth: CGFloat = 64
    public static let tabMaxWidth: CGFloat = 220
    public static let tabCornerRadius: CGFloat = 10
    public static let tabHorizontalPadding: CGFloat = 12
    public static let tabTrailingPadding: CGFloat = 8
    public static let tabSpacing: CGFloat = 8
    public static let shoulderRadius: CGFloat = 8
    public static let topPadding: CGFloat = 7

    // MARK: - Tab Content

    public static let iconSize: CGFloat = 16
    public static let titleFontSize: CGFloat = 12
    public static let closeButtonSize: CGFloat = 20
    public static let closeIconSize: CGFloat = 12
    public static let dirtyIndicatorSize: CGFloat = 8
    public static let contentSpacing: CGFloat = 8

    public static let addButtonWidth: CGFloat = 44
    public static let dropZoneWidth = addButtonWidth - tabSpacing
    public static let hoverBottomInset: CGFloat = 4
    public static let separatorHeight: CGFloat = 16

    // Keep the selected tab and its content brighter than the surrounding strip
    // in light appearance. Overflow masks use the same strip color.
    public static let stripBackground = adaptiveColor(light: 0xebebeb, dark: 0x181818)
    public static let selectedBackground = adaptiveColor(light: 0xf7f7f7, dark: 0x262626)
    public static let hoverBackground = adaptiveColor(light: 0xf1f1f1, dark: 0x222222)
    public static let iconForeground = adaptiveColor(light: 0x4f729e, dark: 0x8cacd8)
    public static let foreground = adaptiveColor(light: 0x242424, dark: 0xececec)
    public static let separator = adaptiveColor(light: 0xc4c4c4, dark: 0x3a3a3a)

    public static func tabWidth(title: String, hasIcon: Bool) -> CGFloat {
        let titleWidth = ceil((title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: titleFontSize)
        ]).width)
        let itemCount: CGFloat = hasIcon ? 4 : 3
        let width = titleWidth + 4 + closeButtonSize + (itemCount - 1) * contentSpacing
            + tabHorizontalPadding + tabTrailingPadding + (hasIcon ? iconSize : 0)
        return min(max(width, 140), tabMaxWidth)
    }

    public static func barWidth(tabWidths: [CGFloat]) -> CGFloat {
        barLeadingPadding + tabWidths.reduce(0, +)
            + CGFloat(max(0, tabWidths.count - 1)) * tabSpacing + addButtonWidth
    }

    private static func adaptiveColor(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255,
                alpha: 1
            )
        }
    }
}
