import Foundation

/// Internal layout and animation metrics. Tab tokens live in BonsplitTabStyle.
enum TabBarMetrics {
    static let barHeight = BonsplitTabStyle.barHeight
    static let tabHeight = BonsplitTabStyle.tabHeight
    static let tabMinWidth = BonsplitTabStyle.tabMinWidth
    static let tabMaxWidth = BonsplitTabStyle.tabMaxWidth
    static let tabCornerRadius = BonsplitTabStyle.tabCornerRadius
    static let tabHorizontalPadding = BonsplitTabStyle.tabHorizontalPadding
    static let tabSpacing = BonsplitTabStyle.tabSpacing
    static let shoulderRadius = BonsplitTabStyle.shoulderRadius
    static let topPadding = BonsplitTabStyle.topPadding
    static let iconSize = BonsplitTabStyle.iconSize
    static let titleFontSize = BonsplitTabStyle.titleFontSize
    static let closeButtonSize = BonsplitTabStyle.closeButtonSize
    static let closeIconSize = BonsplitTabStyle.closeIconSize
    static let dirtyIndicatorSize = BonsplitTabStyle.dirtyIndicatorSize
    static let contentSpacing = BonsplitTabStyle.contentSpacing

    // MARK: - Drop Indicator

    static let dropIndicatorWidth: CGFloat = 2
    static let dropIndicatorHeight: CGFloat = 20

    // MARK: - Split View

    static let minimumPaneWidth: CGFloat = 100
    static let minimumPaneHeight: CGFloat = 100
    static let dividerThickness: CGFloat = 1

    // MARK: - Animations

    static let selectionDuration: Double = 0.15
    static let closeDuration: Double = 0.2
    static let reorderDuration: Double = 0.3
    static let reorderBounce: Double = 0.15
    static let hoverDuration: Double = 0.1

    // MARK: - Split Animations (120fps via CADisplayLink)

    /// Duration for split entry animation (fast and snappy like Hyprland)
    static let splitAnimationDuration: Double = 0.15
}
