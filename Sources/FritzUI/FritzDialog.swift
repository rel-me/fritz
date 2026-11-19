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
