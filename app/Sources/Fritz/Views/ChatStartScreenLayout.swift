import SwiftUI

struct ChatStartScreenLayout<Content: View>: View {
    let composerHeight: CGFloat
    @ViewBuilder let content: () -> Content

    private var composerClearance: CGFloat {
        composerHeight + 24
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    content()
                        .frame(maxWidth: ChatVisualStyle.contentMaxWidth)
                        .frame(maxWidth: .infinity)
                        .frame(
                            minHeight: max(0, geometry.size.height - composerClearance),
                            alignment: .center
                        )

                    Color.clear
                        .frame(height: composerClearance)
                }
                .padding(.horizontal, ChatVisualStyle.horizontalPadding)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
