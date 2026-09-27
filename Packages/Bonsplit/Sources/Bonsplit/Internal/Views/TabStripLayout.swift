import Foundation

/// Fits tabs without scrolling, preserving the selected tab and source order.
struct TabStripLayout {
    static let overflowWidth: CGFloat = 28
    let visibleIndices: [Int]
    let hiddenIndices: [Int]
    let tabWidths: [Int: CGFloat]

    init(preferredWidths: [CGFloat], selectedIndex: Int?, availableWidth: CGFloat, minimumWidth: CGFloat) {
        let spacing = BonsplitTabStyle.tabSpacing
        let minimum = max(1, minimumWidth)
        let budget = max(0, availableWidth - BonsplitTabStyle.barLeadingPadding - BonsplitTabStyle.addButtonWidth)
        let count = preferredWidths.count
        let needsOverflow = CGFloat(count) * minimum + CGFloat(max(0, count - 1)) * spacing > budget
        let tabBudget = max(0, budget - (needsOverflow ? Self.overflowWidth + spacing : 0))
        let capacity = needsOverflow ? max(0, Int((tabBudget + spacing) / (minimum + spacing))) : count
        var visible = Array(0..<min(count, capacity))
        if let selectedIndex, preferredWidths.indices.contains(selectedIndex),
           !visible.contains(selectedIndex), !visible.isEmpty {
            visible[visible.count - 1] = selectedIndex
            visible.sort()
        }
        visibleIndices = visible
        hiddenIndices = preferredWidths.indices.filter { !visible.contains($0) }
        let widthBudget = max(0, tabBudget - CGFloat(max(0, visible.count - 1)) * spacing)
        let preferred = visible.map { max(minimum, preferredWidths[$0]) }
        let excess = preferred.reduce(0) { $0 + $1 - minimum }
        let remaining = max(0, widthBudget - CGFloat(visible.count) * minimum)
        let scale = excess > 0 ? min(1, remaining / excess) : 0
        tabWidths = Dictionary(uniqueKeysWithValues: zip(visible, preferred).map {
            ($0.0, minimum + ($0.1 - minimum) * scale)
        })
    }
}
