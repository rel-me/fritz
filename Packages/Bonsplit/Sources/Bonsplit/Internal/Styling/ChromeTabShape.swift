import SwiftUI

/// Rounded top corners and concave shoulders join the selected tab to its content.
/// The shoulders extend into the tab spacing, leaving the rectangular input area intact.
struct ChromeTabShape: Shape {
    func path(in rect: CGRect) -> Path {
        let top = min(TabBarMetrics.tabCornerRadius, rect.width / 3, rect.height / 2)
        let foot = min(TabBarMetrics.shoulderRadius, rect.height / 2)
        let k: CGFloat = 0.5522847498 // Cubic approximation of a circular quarter arc.
        var path = Path()
        path.move(to: CGPoint(x: rect.minX - foot, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - foot),
            control1: CGPoint(x: rect.minX - foot + k * foot, y: rect.maxY),
            control2: CGPoint(x: rect.minX, y: rect.maxY - foot + k * foot)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + top))
        path.addCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.minY + top - k * top),
            control2: CGPoint(x: rect.minX + top - k * top, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + top),
            control1: CGPoint(x: rect.maxX - top + k * top, y: rect.minY),
            control2: CGPoint(x: rect.maxX, y: rect.minY + top - k * top)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - foot))
        path.addCurve(
            to: CGPoint(x: rect.maxX + foot, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.maxY - foot + k * foot),
            control2: CGPoint(x: rect.maxX + foot - k * foot, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}
