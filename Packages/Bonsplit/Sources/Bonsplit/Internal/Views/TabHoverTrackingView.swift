import AppKit
import SwiftUI

/// Passive tracking keeps tab hover independent of SwiftUI's drag and button views.
struct TabHoverTrackingView: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TabHoverTrackingNSView {
        let view = TabHoverTrackingNSView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: TabHoverTrackingNSView, context: Context) {
        nsView.onChange = onChange
    }
}

final class TabHoverTrackingNSView: NSView {
    var onChange: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?
    private var isHovered = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
        refreshHover()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshHover()
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) { updateHover(at: nil) }

    private func refreshHover() {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else {
            updateHover(at: nil)
            return
        }
        updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    func updateHover(at point: NSPoint?) {
        let hovering = point.map { bounds.intersection(visibleRect).contains($0) } ?? false
        guard hovering != isHovered else { return }
        isHovered = hovering
        // Tracking areas can refresh during SwiftUI layout. Publish after that update.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isHovered == hovering else { return }
            self.onChange?(hovering)
        }
    }
}
