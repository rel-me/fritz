import Foundation

public enum AppUpdateChannel: String, CaseIterable, Identifiable, Sendable {
    case release
    case beta
    case dev

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .release: "Release"
        case .beta: "Beta"
        case .dev: "Dev"
        }
    }

    public var allowedSparkleChannels: Set<String> {
        switch self {
        case .release: []
        case .beta: ["beta"]
        case .dev: ["beta", "dev"]
        }
    }

    public static var saved: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: "updateChannel") ?? "") ?? .release
    }
}
