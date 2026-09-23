import AppKit
import Foundation

public enum AppAppearance: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public static var saved: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system
    }

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    @MainActor
    public var appKitAppearance: NSAppearance? {
        switch self {
        case .system:
            nil
        case .light:
            NSAppearance(named: .aqua)
        case .dark:
            NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    public func apply(to application: NSApplication) {
        application.appearance = appKitAppearance
    }
}
