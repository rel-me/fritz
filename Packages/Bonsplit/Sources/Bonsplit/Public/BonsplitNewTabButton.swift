import SwiftUI

/// Shared trailing action for tab strips. Its background matches the host strip.
public struct BonsplitNewTabButton: View {
    private let title: String
    private let background: Color
    private let action: () -> Void
    @State private var isHovered = false

    public init(_ title: String, background: Color = Color(nsColor: BonsplitTabStyle.stripBackground),
                action: @escaping () -> Void) {
        self.title = title
        self.background = background
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
                .labelStyle(.iconOnly)
                .font(.system(size: 16, weight: .regular))
                .frame(width: 30, height: 30)
                .background {
                    if isHovered {
                        Circle().fill(Color(nsColor: BonsplitTabStyle.hoverBackground))
                    }
                }
                .offset(y: 3)
                .frame(width: BonsplitTabStyle.addButtonWidth, height: BonsplitTabStyle.barHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(nsColor: BonsplitTabStyle.foreground))
        .background(background)
        .onHover { isHovered = $0 }
        .help(title)
    }
}
