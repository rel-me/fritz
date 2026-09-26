import Foundation

struct ChatScrollState {
    private(set) var followsLatest = true

    init(followsLatest: Bool = true) {
        self.followsLatest = followsLatest
    }

    struct Geometry: Equatable {
        let contentHeight: CGFloat
        let viewportHeight: CGFloat
        let visibleBottom: CGFloat

        var isNearBottom: Bool {
            contentHeight - visibleBottom <= 80
        }
    }

    /// Only user scrolling can leave the latest content. Lazy layout and
    /// automatic offset adjustments can report transient positions far from it.
    mutating func update(to new: Geometry, isUserScrolling: Bool) {
        if isUserScrolling || new.isNearBottom {
            followsLatest = new.isNearBottom
        }
    }
}
