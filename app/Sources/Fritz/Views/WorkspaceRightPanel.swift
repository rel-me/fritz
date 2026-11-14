import SwiftUI

/// Manual browsing beside the conversation, with tabs owned by the workspace.
struct WorkspaceRightPanel: View {
    let tabs: BrowserTabs

    var body: some View {
        BrowserPanel(tabs: tabs)
        .clipShape(RoundedRectangle(cornerRadius: FritzWindowStyle.cornerRadius, style: .continuous))
        .padding(.leading, 4).padding(.trailing, 8).padding(.bottom, 8)
    }
}

/// Sets the native divider once per opening, then leaves resizing to AppKit.
/// SwiftUI's ideal inspector width alone preserves a previously dragged width.
struct BrowserInspectorSizing: NSViewRepresentable {
    let openingID: Int

    func makeNSView(context: Context) -> SizingView { SizingView() }

    func updateNSView(_ view: SizingView, context: Context) {
        guard view.openingID != openingID else { return }
        view.openingID = openingID
        view.needsOpeningWidth = true
        // Apply after SwiftUI has expanded the native inspector and laid out
        // the navigation columns. Ignore requests superseded by another opening.
        DispatchQueue.main.async { [weak view] in
            guard let view, view.openingID == openingID,
                  let root = view.window?.contentView else { return }
            root.layoutSubtreeIfNeeded()
            view.resizeInspector(in: root)
        }
    }

    final class SizingView: NSView {
        var openingID: Int?
        var needsOpeningWidth = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            NotificationCenter.default.addObserver(
                self, selector: #selector(splitDidResize(_:)),
                name: NSSplitView.didResizeSubviewsNotification, object: nil
            )
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let root = self.window?.contentView else { return }
                self.resizeInspector(in: root)
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func splitDidResize(_ notification: Notification) {
            guard needsOpeningWidth, let root = window?.contentView else { return }
            resizeInspector(in: root)
        }

        func resizeInspector(in view: NSView) {
            guard needsOpeningWidth else { return }
            if let split = view as? NSSplitView, split.isVertical,
               split.arrangedSubviews.count == 2,
               let navigation = navigationSplit(in: split.arrangedSubviews[0]),
               let sidebar = navigation.arrangedSubviews.first {
                // Native expansion can finish after SwiftUI's update callback.
                // Wait for its resize notification instead of sizing a collapsed item.
                guard split.arrangedSubviews[1].frame.width >= 320 else { return }
                let sidebarEnd = split.convert(sidebar.bounds, from: sidebar).maxX
                    + navigation.dividerThickness
                let width = max(320, (split.bounds.maxX - sidebarEnd) / 2)
                needsOpeningWidth = false
                split.setPosition(split.bounds.maxX - width - split.dividerThickness,
                                  ofDividerAt: 0)
                return
            }
            for child in view.subviews { resizeInspector(in: child) }
        }

        private func navigationSplit(in view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView,
               split.isVertical, split.arrangedSubviews.count > 1 { return split }
            for child in view.subviews {
                if let split = navigationSplit(in: child) { return split }
            }
            return nil
        }
    }
}
