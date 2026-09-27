import SwiftUI

/// Individual tab view with icon, title, close button, and dirty indicator
struct TabItemView: View {
    let tab: TabItem
    let isSelected: Bool
    let allowsClose: Bool
    var showsSeparator: Bool = true
    var allocatedWidth: CGFloat? = nil
    let appearance: BonsplitConfiguration.Appearance
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false
    @State private var isCloseHovered = false

    private var isCloseVisible: Bool {
        Self.showsCloseButton(
            allowsClose: allowsClose, isDirty: tab.isDirty,
            isHovered: isHovered, isCloseHovered: isCloseHovered
        )
    }

    private var isCompact: Bool {
        (allocatedWidth ?? appearance.tabMaxWidth) < 100
    }

    var body: some View {
        HStack(spacing: TabBarMetrics.contentSpacing) {
            // Icon
            if let iconName = tab.icon {
                Image(systemName: iconName)
                    .font(.system(size: TabBarMetrics.iconSize))
                    .frame(width: TabBarMetrics.iconSize, height: TabBarMetrics.iconSize)
                    .foregroundStyle(Color(nsColor: BonsplitTabStyle.iconForeground))
            }

            if !isCompact || tab.icon == nil {
                Text(tab.title)
                    .font(.system(size: TabBarMetrics.titleFontSize))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? TabBarColors.activeText : TabBarColors.inactiveText)
            }

            if !isCompact {
                Spacer(minLength: 4)
            }

            // Close button or dirty indicator
            if allowsClose || tab.isDirty {
                closeOrDirtyIndicator
            }
        }
        .padding(.leading, TabBarMetrics.tabHorizontalPadding)
        .padding(.trailing, BonsplitTabStyle.tabTrailingPadding)
        .frame(
            minWidth: allocatedWidth ?? appearance.tabMinWidth,
            maxWidth: allocatedWidth ?? appearance.tabMaxWidth,
            minHeight: TabBarMetrics.tabHeight,
            maxHeight: TabBarMetrics.tabHeight
        )
        .background(tabBackground)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .background {
            TabHoverTrackingView { hovering in
                isHovered = hovering
                if !hovering { isCloseHovered = false }
            }
        }
        .accessibilityElement(children: .combine)
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityValue(tab.isDirty ? "Modified" : "")
        .accessibilityAction { onSelect() }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Tab Background

    @ViewBuilder
    private var tabBackground: some View {
        ZStack {
            if isSelected {
                ChromeTabShape()
                    .fill(TabBarColors.activeTabBackground(for: appearance))
            } else if isHovered {
                RoundedRectangle(cornerRadius: TabBarMetrics.tabCornerRadius)
                    .fill(TabBarColors.hoveredTabBackground)
                    .padding(.bottom, BonsplitTabStyle.hoverBottomInset)
            }

            if !isSelected && !isHovered && showsSeparator {
                Rectangle()
                    .fill(TabBarColors.separator)
                    .frame(width: 1, height: BonsplitTabStyle.separatorHeight)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .offset(x: TabBarMetrics.tabSpacing / 2)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Close Button / Dirty Indicator

    @ViewBuilder
    private var closeOrDirtyIndicator: some View {
        ZStack {
            // Dirty indicator (shown when dirty and not hovering)
            if tab.isDirty && (!allowsClose || (!isHovered && !isCloseHovered)) {
                Circle()
                    .fill(TabBarColors.dirtyIndicator)
                    .frame(width: TabBarMetrics.dirtyIndicatorSize, height: TabBarMetrics.dirtyIndicatorSize)
            }

            // Keep the close target reserved so revealing it never shifts the title.
            if allowsClose {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: TabBarMetrics.closeIconSize, weight: .regular))
                        .foregroundStyle(isCloseHovered ? TabBarColors.activeText : TabBarColors.inactiveText)
                        .frame(width: TabBarMetrics.closeButtonSize, height: TabBarMetrics.closeButtonSize)
                        .background(
                            Circle()
                                .fill(isCloseHovered ? TabBarColors.hoveredTabBackground : .clear)
                        )
                }
                .buttonStyle(.plain)
                .opacity(isCloseVisible ? 1 : 0)
                .allowsHitTesting(isCloseVisible)
                .accessibilityHidden(!isCloseVisible)
                .accessibilityLabel("Close \(tab.title)")
                .help("Close tab")
                .onHover { hovering in
                    isCloseHovered = hovering
                }
            }
        }
        .frame(width: TabBarMetrics.closeButtonSize, height: TabBarMetrics.closeButtonSize)
        .animation(.easeInOut(duration: TabBarMetrics.hoverDuration), value: isHovered)
        .animation(.easeInOut(duration: TabBarMetrics.hoverDuration), value: isCloseHovered)
    }

    static func showsCloseButton(
        allowsClose: Bool,
        isDirty: Bool = false,
        isHovered: Bool,
        isCloseHovered: Bool
    ) -> Bool {
        allowsClose && (isHovered || isCloseHovered)
    }
}
