import XCTest
@testable import Bonsplit

final class TabStripLayoutTests: XCTestCase {
    func testCompactTabsFitBeforeOverflowAndKeepSelectionWhenFull() {
        let fitting = TabStripLayout(preferredWidths: Array(repeating: 220, count: 8),
                                    selectedIndex: 7, availableWidth: 728, minimumWidth: 64)
        XCTAssertTrue(fitting.hiddenIndices.isEmpty)
        XCTAssertEqual(fitting.visibleIndices.count, 8)
        let overflowing = TabStripLayout(preferredWidths: Array(repeating: 220, count: 16),
                                        selectedIndex: 15, availableWidth: 728, minimumWidth: 64)
        XCTAssertEqual(overflowing.visibleIndices.count, 9)
        XCTAssertEqual(overflowing.visibleIndices.last, 15)
        XCTAssertTrue(overflowing.tabWidths.values.allSatisfy { $0 >= 64 })
    }

    func testShrinksBeforeOverflow() {
        let layout = TabStripLayout(preferredWidths: [220, 220, 220], selectedIndex: 2,
                                    availableWidth: 600, minimumWidth: 140)
        XCTAssertEqual(layout.visibleIndices, [0, 1, 2])
        XCTAssertTrue(layout.hiddenIndices.isEmpty)
        XCTAssertEqual(layout.tabWidths.values.reduce(0, +), 532, accuracy: 0.001)
    }

    func testOverflowKeepsSelectedTabInSourceOrder() {
        let layout = TabStripLayout(preferredWidths: Array(repeating: 220, count: 8), selectedIndex: 7,
                                    availableWidth: 600, minimumWidth: 140)
        XCTAssertEqual(layout.visibleIndices, [0, 1, 7])
        XCTAssertEqual(layout.hiddenIndices, [2, 3, 4, 5, 6])
        XCTAssertTrue(layout.tabWidths.values.allSatisfy { $0 >= 140 })
        XCTAssertLessThanOrEqual(layout.tabWidths.values.reduce(0, +) + 16 + 36 + 52, 600.001)
    }

    func testExactMinimumBoundaryAndEmptyStrip() {
        let exact = TabStripLayout(preferredWidths: [220, 220], selectedIndex: 1,
                                   availableWidth: 340, minimumWidth: 140)
        XCTAssertTrue(exact.hiddenIndices.isEmpty)
        XCTAssertEqual(exact.tabWidths[0], 140)
        let empty = TabStripLayout(preferredWidths: [], selectedIndex: nil,
                                   availableWidth: 0, minimumWidth: 140)
        XCTAssertTrue(empty.visibleIndices.isEmpty)
    }

    func testResizeRestoresAllTabsAndDoesNotStretchShortTitles() {
        let layout = TabStripLayout(preferredWidths: [140, 220, 180], selectedIndex: 2,
                                    availableWidth: 1000, minimumWidth: 140)
        XCTAssertEqual(layout.visibleIndices, [0, 1, 2])
        XCTAssertEqual(layout.tabWidths, [0: 140, 1: 220, 2: 180])
    }
}
