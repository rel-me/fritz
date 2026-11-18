import SwiftUI

/// Layout for a custom sheet attached to a Fritz window.
public struct FritzDialog<Content: View, Actions: View>: View {
    private let title: String?
    private let content: Content
    private let actions: Actions

    public init(_ title: String? = nil, @ViewBuilder content: () -> Content,
                @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.content = content()
        self.actions = actions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 24)
            }
            content
            HStack(spacing: 8) { actions }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 24)
                .padding(.top, 4)
        }
        .padding(.vertical, 4)
        .buttonStyle(.automatic)
    }
}
