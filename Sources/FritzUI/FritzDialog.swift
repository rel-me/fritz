import AppKit
import SwiftUI

/// Layout for a custom sheet attached to a Fritz window.
public struct FritzDialog<Content: View, Actions: View>: View {
    private let title: String?
    private let separatesActions: Bool
    private let content: Content
    private let actions: Actions

    public init(_ title: String? = nil, separatesActions: Bool = false, @ViewBuilder content: () -> Content,
                @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.separatesActions = separatesActions
        self.content = content()
        self.actions = actions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if let title {
                    Text(title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, 24)
                }
                content
            }
            if separatesActions {
                Spacer(minLength: 12)
                Divider()
            }
            HStack(spacing: 8) { actions }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 24)
                .padding(.top, separatesActions ? 8 : 16)
                .padding(.bottom, separatesActions ? 8 : 0)
        }
        .padding(.vertical, 4)
        .buttonStyle(.automatic)
    }
}

public extension View {
    /// Keep content-sized sheets fitted when progress, results, or errors change their height.
    func fritzFittedSheet() -> some View {
        fixedSize(horizontal: false, vertical: true)
            .background { FritzSheetSizing() }
            .presentationSizing(.fitted)
    }
}

/// SwiftUI fits the attached window at presentation. Track changes after that initial fit.
private struct FritzSheetSizing: NSViewRepresentable {
    func makeNSView(context: Context) -> SizingView { SizingView() }

    func updateNSView(_ view: SizingView, context: Context) {}

    final class SizingView: NSView {
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            resizeSheet()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resizeSheet()
        }

        private func resizeSheet() {
            // Resize after SwiftUI finishes laying out the sheet content.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window, window.sheetParent != nil,
                      let content = window.contentView,
                      frame.height > 0, abs(content.frame.height - frame.height) >= 1 else { return }
                window.setContentSize(NSSize(width: content.frame.width, height: frame.height))
            }
        }
    }
}
