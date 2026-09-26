import SwiftUI

enum ChatVisualStyle {
    static let contentMaxWidth: CGFloat = 720
    static let horizontalPadding: CGFloat = 24
    static let transcriptSpacing: CGFloat = 28
    static let composerCornerRadius = FritzWindowStyle.cornerRadius
    static let composerShadowRadius: CGFloat = 6
    static let composerShadowY: CGFloat = 2

    static let pageBackgroundNSColor = FritzWindowStyle.contentBackgroundNSColor
    static let pageBackground = Color(nsColor: pageBackgroundNSColor)
    static let composerBackground = Color(nsColor: .textBackgroundColor)

    static func composerShadow(for colorScheme: ColorScheme) -> Color {
        Color.black.opacity(colorScheme == .dark ? 0.12 : 0.04)
    }

    static let composerSecondaryForeground = Color.secondary

    static func composerDisabledSendBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(.sRGB, white: 65.0 / 255.0, opacity: 1)
            : Color.primary.opacity(0.14)
    }

    static var hairline: Color {
        Color(nsColor: .separatorColor).opacity(0.72)
    }

    static var subtleFill: Color {
        Color.primary.opacity(0.055)
    }

    static var quieterFill: Color {
        Color.primary.opacity(0.035)
    }

    static var modelPickerSelectionFill: Color {
        Color.primary.opacity(0.11)
    }
}
