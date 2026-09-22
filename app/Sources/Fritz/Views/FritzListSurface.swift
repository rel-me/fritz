import SwiftUI

/// Shared surface for record lists and tables. Apply directly to the collection,
/// keeping headings, help, and feedback outside it. Navigation sidebars retain
/// their native sidebar style.
struct FritzListSurface: ViewModifier {
    let background: Color?

    // A small semantic tint keeps the surface distinct even when macOS gives
    // controls and windows the same base color. Resolve both colors in the
    // requested appearance so SwiftUI and AppKit also follow contrast changes.
    static let backgroundNSColor = NSColor(name: nil) { appearance in
        var color = NSColor.controlBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.controlBackgroundColor.blended(
                withFraction: 0.04,
                of: .labelColor
            ) ?? .controlBackgroundColor
        }
        return color
    }
    static let background = Color(nsColor: backgroundNSColor)

    func body(content: Content) -> some View {
        content
            .fritzButtonSize(.regular)
            .scrollContentBackground(.hidden)
            .alternatingRowBackgrounds(.disabled)
            .background(background ?? Self.background)
    }
}

extension View {
    /// Gives a native List or Table Fritz’s adaptive collection background without
    /// changing its selection, keyboard navigation, columns, or context menus.
    func fritzListSurface(background: Color? = nil) -> some View {
        modifier(FritzListSurface(background: background))
    }
}
