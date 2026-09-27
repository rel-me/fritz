import SwiftUI

public struct ChatStartScreenLayout<Content: View>: View {
    let composerHeight: CGFloat
    @ViewBuilder let content: () -> Content

    public init(composerHeight: CGFloat, @ViewBuilder content: @escaping () -> Content) {
        self.composerHeight = composerHeight
        self.content = content
    }

    private var composerClearance: CGFloat {
        composerHeight + 24
    }

    public var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    content()
                        .frame(maxWidth: 720)
                        .frame(maxWidth: .infinity)
                        .frame(
                            minHeight: max(0, geometry.size.height - composerClearance),
                            alignment: .center
                        )

                    Color.clear
                        .frame(height: composerClearance)
                }
                .padding(.horizontal, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
